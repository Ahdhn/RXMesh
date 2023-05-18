#pragma once
#include "rxmesh/rxmesh_static.h"

#include <cooperative_groups.h>

#include "rxmesh/bitmask.cuh"

namespace rxmesh {
namespace detail {

template <uint32_t blockThreads>
__inline__ __device__ void bi_assignment(
    cooperative_groups::thread_block& block,
    const uint16_t                    num_vertices,
    const uint16_t                    num_edges,
    const uint16_t                    num_faces,
    const Bitmask&                    s_owned_v,
    const Bitmask&                    s_owned_e,
    const Bitmask&                    s_owned_f,
    const Bitmask&                    s_active_v,
    const Bitmask&                    s_active_e,
    const Bitmask&                    s_active_f,
    const uint16_t*                   s_ev,
    const uint16_t*                   s_fv,
    Bitmask&                          s_new_p_owned_v,
    Bitmask&                          s_new_p_owned_e,
    Bitmask&                          s_new_p_owned_f);
template <uint32_t blockThreads>
__inline__ __device__ void slice(Context&                          context,
                                 cooperative_groups::thread_block& block,
                                 PatchInfo&                        pi,
                                 const uint32_t                    new_patch_id,
                                 const uint16_t                    num_vertices,
                                 const uint16_t                    num_edges,
                                 const uint16_t                    num_faces,
                                 PatchStash&     s_new_patch_stash,
                                 Bitmask&        s_owned_v,
                                 Bitmask&        s_owned_e,
                                 Bitmask&        s_owned_f,
                                 const Bitmask&  s_active_v,
                                 const Bitmask&  s_active_e,
                                 const Bitmask&  s_active_f,
                                 const uint16_t* s_ev,
                                 const uint16_t* s_fe,
                                 Bitmask&        s_new_p_active_v,
                                 Bitmask&        s_new_p_active_e,
                                 Bitmask&        s_new_p_active_f,
                                 Bitmask&        s_new_p_owned_v,
                                 Bitmask&        s_new_p_owned_e,
                                 Bitmask&        s_new_p_owned_f);

template <uint32_t blockThreads, typename AttributeT>
__inline__ __device__ void post_slicing_update_attributes(
    const PatchInfo& pi,
    const uint32_t   new_patch_id,
    const Bitmask&   ownership_change_v,
    const Bitmask&   ownership_change_e,
    const Bitmask&   ownership_change_f,
    AttributeT&      attribute)
{
    using HandleT = typename AttributeT::HandleType;

    const uint32_t num_attr = attribute.get_num_attributes();

    const uint16_t num_elements = pi.get_num_elements<HandleT>()[0];

    const uint32_t patch_id = pi.patch_id;


    for (uint16_t vp = threadIdx.x; vp < num_elements; vp += blockThreads) {
        bool change = false;
        if constexpr (std::is_same_v<HandleT, VertexHandle>) {
            change = ownership_change_v(vp);
        }
        if constexpr (std::is_same_v<HandleT, EdgeHandle>) {
            change = ownership_change_e(vp);
        }
        if constexpr (std::is_same_v<HandleT, FaceHandle>) {
            change = ownership_change_f(vp);
        }
        if (change) {
            for (uint32_t attr = 0; attr < num_attr; ++attr) {
                attribute(new_patch_id, vp, attr) =
                    attribute(patch_id, vp, attr);
            }
        }
    }
}


template <uint32_t blockThreads, typename... AttributesT>
__global__ static void slice_patches(Context        context,
                                     const uint32_t current_num_patches,
                                     const uint32_t num_faces_threshold,
                                     AttributesT... attributes)
{
    // ev, fe, active_v/e/f, owned_v/e/f, patch_v/e/f
    auto block = cooperative_groups::this_thread_block();

    ShmemAllocator shrd_alloc;

    const uint32_t pid = blockIdx.x;
    if (pid >= current_num_patches) {
        return;
    }

    PatchInfo pi = context.m_patches_info[pid];

    const uint16_t num_vertices = pi.num_vertices[0];
    const uint16_t num_edges    = pi.num_edges[0];
    const uint16_t num_faces    = pi.num_faces[0];


    auto alloc_masks = [&](uint16_t        num_elements,
                           Bitmask&        owned,
                           Bitmask&        active,
                           Bitmask&        new_active,
                           Bitmask&        patch,
                           Bitmask&        ribbon,
                           const uint32_t* g_owned,
                           const uint32_t* g_active) {
        owned      = Bitmask(num_elements, shrd_alloc);
        active     = Bitmask(num_elements, shrd_alloc);
        new_active = Bitmask(num_elements, shrd_alloc);
        patch      = Bitmask(num_elements, shrd_alloc);
        ribbon     = Bitmask(num_elements, shrd_alloc);

        owned.reset(block);
        active.reset(block);
        new_active.reset(block);
        patch.reset(block);
        ribbon.reset(block);

        // to remove the racecheck hazard report due to WAW on owned and active
        block.sync();

        detail::load_async(block,
                           reinterpret_cast<const char*>(g_owned),
                           owned.num_bytes(),
                           reinterpret_cast<char*>(owned.m_bitmask),
                           false);
        detail::load_async(block,
                           reinterpret_cast<const char*>(g_active),
                           active.num_bytes(),
                           reinterpret_cast<char*>(active.m_bitmask),
                           false);
    };


    if (num_faces >= num_faces_threshold) {
        __shared__ uint32_t s_new_patch_id;
        if (threadIdx.x == 0) {
            s_new_patch_id = ::atomicAdd(context.m_num_patches, uint32_t(1));
            assert(s_new_patch_id < context.m_max_num_patches);
        }
        Bitmask s_owned_v, s_owned_e, s_owned_f;
        Bitmask s_active_v, s_active_e, s_active_f;
        Bitmask s_new_p_owned_v, s_new_p_owned_e, s_new_p_owned_f;
        Bitmask s_new_p_active_v, s_new_p_active_e, s_new_p_active_f;
        Bitmask s_ribbon_v, s_ribbon_e, s_ribbon_f;


        uint16_t* s_ev = shrd_alloc.alloc<uint16_t>(2 * num_edges);
        detail::load_async(block,
                           reinterpret_cast<uint16_t*>(pi.ev),
                           2 * num_edges,
                           s_ev,
                           false);
        uint16_t* s_fe = shrd_alloc.alloc<uint16_t>(3 * num_faces);
        uint16_t* s_fv = s_fe;
        detail::load_async(block,
                           reinterpret_cast<uint16_t*>(pi.fe),
                           3 * num_faces,
                           s_fe,
                           true);

        PatchStash s_new_patch_stash;
        s_new_patch_stash.m_stash =
            shrd_alloc.alloc<uint32_t>(PatchStash::stash_size);

        alloc_masks(num_vertices,
                    s_owned_v,
                    s_active_v,
                    s_new_p_active_v,
                    s_new_p_owned_v,
                    s_ribbon_v,
                    pi.owned_mask_v,
                    pi.active_mask_v);
        alloc_masks(num_edges,
                    s_owned_e,
                    s_active_e,
                    s_new_p_active_e,
                    s_new_p_owned_e,
                    s_ribbon_e,
                    pi.owned_mask_e,
                    pi.active_mask_e);
        alloc_masks(num_faces,
                    s_owned_f,
                    s_active_f,
                    s_new_p_active_f,
                    s_new_p_owned_f,
                    s_ribbon_f,
                    pi.owned_mask_f,
                    pi.active_mask_f);

        block.sync();
        f_v<blockThreads>(
            num_edges, s_ev, num_faces, s_fv, s_active_f.m_bitmask);
        block.sync();

        bi_assignment<blockThreads>(block,
                                    num_vertices,
                                    num_edges,
                                    num_faces,
                                    s_owned_v,
                                    s_owned_e,
                                    s_owned_f,
                                    s_active_v,
                                    s_active_e,
                                    s_active_f,
                                    s_ev,
                                    s_fv,
                                    s_new_p_owned_v,
                                    s_new_p_owned_e,
                                    s_new_p_owned_f);
        block.sync();


        detail::load_async(block,
                           reinterpret_cast<uint16_t*>(pi.fe),
                           3 * num_faces,
                           s_fe,
                           true);

        block.sync();

        slice<blockThreads>(context,
                            block,
                            pi,
                            s_new_patch_id,
                            num_vertices,
                            num_edges,
                            num_faces,
                            s_new_patch_stash,
                            s_owned_v,
                            s_owned_e,
                            s_owned_f,
                            s_active_v,
                            s_active_e,
                            s_active_f,
                            s_ev,
                            s_fe,
                            s_new_p_active_v,
                            s_new_p_active_e,
                            s_new_p_active_f,
                            s_new_p_owned_v,
                            s_new_p_owned_e,
                            s_new_p_owned_f);

        (
            [&] {
                post_slicing_update_attributes<blockThreads>(pi,
                                                             s_new_patch_id,
                                                             s_new_p_owned_v,
                                                             s_new_p_owned_e,
                                                             s_new_p_owned_f,
                                                             attributes);
            }(),
            ...);

#ifndef NDEBUG
        block.sync();

        for (uint16_t v = threadIdx.x; v < num_vertices; v += blockThreads) {
            bool was_active = s_active_v(v);
            bool is_active_p =
                !context.m_patches_info[pid].is_deleted(LocalVertexT(v));
            bool is_active_new =
                !context.m_patches_info[s_new_patch_id].is_deleted(
                    LocalVertexT(v));
            if (was_active) {
                assert(is_active_p || is_active_new);
            } else {
                assert(!is_active_p && !is_active_new);
            }
        }

        for (uint16_t e = threadIdx.x; e < num_edges; e += blockThreads) {
            bool was_active = s_active_e(e);
            bool is_active_p =
                !context.m_patches_info[pid].is_deleted(LocalEdgeT(e));
            bool is_active_new =
                !context.m_patches_info[s_new_patch_id].is_deleted(
                    LocalEdgeT(e));
            if (was_active) {
                assert(is_active_p || is_active_new);
            } else {
                assert(!is_active_p && !is_active_new);
            }
        }

        for (uint16_t f = threadIdx.x; f < num_faces; f += blockThreads) {
            bool was_active = s_active_f(f);
            bool is_active_p =
                !context.m_patches_info[pid].is_deleted(LocalFaceT(f));
            bool is_active_new =
                !context.m_patches_info[s_new_patch_id].is_deleted(
                    LocalFaceT(f));
            if (was_active) {
                assert(is_active_p || is_active_new);
            } else {
                assert(!is_active_p && !is_active_new);
            }
        }
#endif
    }
}
}  // namespace detail


class RXMeshDynamic : public RXMeshStatic
{
   public:
    RXMeshDynamic(const RXMeshDynamic&) = delete;

    /**
     * @brief Constructor using path to obj file
     * @param file_path path to an obj file
     * @param quite run in quite mode
     */
    RXMeshDynamic(const std::string file_path,
                  const bool        quite        = false,
                  const std::string patcher_file = "")
        : RXMeshStatic(file_path, quite, patcher_file)
    {
    }

    /**
     * @brief Constructor using triangles and vertices
     * @param fv Face incident vertices as read from an obj file
     * @param quite run in quite mode
     */
    RXMeshDynamic(std::vector<std::vector<uint32_t>>& fv,
                  const bool                          quite        = false,
                  const std::string                   patcher_file = "")
        : RXMeshStatic(fv, quite, patcher_file)
    {
    }

    /**
     * @brief save/seralize the patcher info to a file
     * @param filename
     */
    virtual void save(std::string filename) override;

    /**
     * @brief populate the launch_box with grid size and dynamic shared memory
     * needed for a kernel that may use dynamic and query operations
     * @param op List of query operations done inside the kernel
     * @param launch_box input launch box to be populated
     * @param kernel The kernel to be launched
     * @param oriented if the query is oriented. Valid only for Op::VV queries
     */
    template <uint32_t blockThreads>
    void prepare_launch_box(const std::vector<Op>    op,
                            LaunchBox<blockThreads>& launch_box,
                            const void*              kernel,
                            const bool               oriented = false) const
    {

        launch_box.blocks = this->m_num_patches;

        size_t static_shmem = 0;
        for (auto o : op) {
            static_shmem =
                std::max(static_shmem,
                         this->calc_shared_memory<blockThreads>(o, oriented));
        }

        uint16_t vertex_cap = static_cast<uint16_t>(
            this->m_capacity_factor *
            static_cast<float>(this->m_max_vertices_per_patch));

        uint16_t edge_cap = static_cast<uint16_t>(
            this->m_capacity_factor *
            static_cast<float>(this->m_max_edges_per_patch));

        uint16_t face_cap = static_cast<uint16_t>(
            this->m_capacity_factor *
            static_cast<float>(this->m_max_faces_per_patch));

        // To load EV and FE
        size_t dyn_shmem = 3 * face_cap * sizeof(uint16_t) +
                           2 * edge_cap * sizeof(uint16_t) +
                           2 * ShmemAllocator::default_alignment;

        // cavity ID
        dyn_shmem += std::max(
            vertex_cap * sizeof(uint16_t),
            max_lp_hashtable_capacity<LocalVertexT>() * sizeof(LPPair));
        dyn_shmem +=
            std::max(edge_cap * sizeof(uint16_t),
                     max_lp_hashtable_capacity<LocalEdgeT>() * sizeof(LPPair));
        dyn_shmem +=
            std::max(face_cap * sizeof(uint16_t),
                     max_lp_hashtable_capacity<LocalFaceT>() * sizeof(LPPair));

        dyn_shmem += 3 * ShmemAllocator::default_alignment;

        // cavity loop
        dyn_shmem += this->m_max_edges_per_patch * sizeof(uint16_t) +
                     ShmemAllocator::default_alignment;

        // store number of cavities and patches to lock
        dyn_shmem += 3 * sizeof(int) + ShmemAllocator::default_alignment;


        // store cavity size (assume number of cavities is half the patch size)
        dyn_shmem += (this->m_max_faces_per_patch / 2) * sizeof(int) +
                     ShmemAllocator::default_alignment;

        // active, owned, migrate(for vertices only), src bitmask (for vertices
        // and edges only), src connect (for vertices and edges only), ownership
        // owned_cavity_bdry (for vertices only), ribbonize (for vertices only)
        // added_to_lp, in_cavity
        dyn_shmem += 10 * detail::mask_num_bytes(vertex_cap) +
                     10 * ShmemAllocator::default_alignment;
        dyn_shmem += 7 * detail::mask_num_bytes(edge_cap) +
                     7 * ShmemAllocator::default_alignment;
        dyn_shmem += 5 * detail::mask_num_bytes(face_cap) +
                     5 * ShmemAllocator::default_alignment;

        // patch stash
        dyn_shmem += PatchStash::stash_size * sizeof(uint32_t);

        if (!this->m_quite) {
            RXMESH_TRACE(
                "RXMeshDynamic::calc_shared_memory() launching {} blocks with "
                "{} threads on the device",
                launch_box.blocks,
                blockThreads);
        }

        // since we are either doing static query or dynamic changes,
        // shared memory is the max of both
        launch_box.smem_bytes_dyn = std::max(dyn_shmem, static_shmem);

        check_shared_memory(launch_box.smem_bytes_dyn,
                            launch_box.smem_bytes_static,
                            launch_box.num_registers_per_thread,
                            blockThreads,
                            kernel);
    }

    virtual ~RXMeshDynamic() = default;

    /**
     * @brief check if there is remaining patches not processed yet
     */
    bool is_queue_empty(cudaStream_t stream = NULL)
    {
        return this->m_rxmesh_context.m_patch_scheduler.is_empty(stream);
    }


    /**
     * @brief reset the patches for a another kernel. This needs only to be
     * called where more than one kernel is called. For a single kernel, the
     * queue is initialized during the construction so the user does not to call
     * this
     */
    void reset_queue()
    {
        this->m_rxmesh_context.m_patch_scheduler.refill();
    }

    /**
     * @brief Validate the topology information stored in RXMesh. All checks are
     * done on the information stored on the GPU memory and thus all checks are
     * done on the GPU
     * @return true in case all information stored are valid
     */
    bool validate();

    /**
     * @brief cleanup after topology changes by removing surplus elements
     * and make sure that hashtable store owner patches
     */
    void cleanup();

    /**
     * @brief slice a patch if the number of faces in the patch is greater
     * than a threshold
     */
    template <typename... AttributesT>
    void slice_patches(const uint32_t num_faces_threshold,
                       AttributesT... attributes)
    {
        constexpr uint32_t block_size = 256;
        const uint32_t     grid_size  = get_num_patches();


        // ev, fe
        uint32_t dyn_shmem =
            2 * ShmemAllocator::default_alignment +
            (3 * this->m_max_faces_per_patch) * sizeof(uint16_t) +
            (2 * this->m_max_edges_per_patch) * sizeof(uint16_t);

        // active_v/e/f, owned_v/e/f, patch_v/e/f
        dyn_shmem +=
            5 * detail::mask_num_bytes(this->m_max_vertices_per_patch) +
            5 * ShmemAllocator::default_alignment;

        dyn_shmem += 5 * detail::mask_num_bytes(this->m_max_edges_per_patch) +
                     5 * ShmemAllocator::default_alignment;

        dyn_shmem += 5 * detail::mask_num_bytes(this->m_max_faces_per_patch) +
                     5 * ShmemAllocator::default_alignment;

        dyn_shmem += PatchStash::stash_size * sizeof(uint32_t);

        detail::slice_patches<block_size>
            <<<grid_size, block_size, dyn_shmem>>>(this->m_rxmesh_context,
                                                   get_num_patches(),
                                                   num_faces_threshold,
                                                   attributes...);
    }

    void copy_patch_debug(const uint32_t                  pid,
                          rxmesh::VertexAttribute<float>& coords);

    /**
     * @brief update the host side. Use this function to update the host side
     * after performing (dynamic) updates on the GPU. This function may
     * re-allocates the host side memory buffers in case it is not enough (e.g.,
     * after performing mesh refinement on the GPU)
     */
    void update_host();

    /**
     * @brief update polyscope after performing dynamic changes. This function
     * is supposed to be called after a call to update_host since polyscope
     * reads information from the host side of RXMesh which include the topology
     * (stored in RXMesh/RXMeshStatic/RXMeshDynamic) and the input vertex
     * coordinates as well. Thus, a call to `move(DEVICE, HOST)` should be done
     * to RXMesh-stored vertex coordinates before calling this function.
     */
    void update_polyscope();
};
}  // namespace rxmesh