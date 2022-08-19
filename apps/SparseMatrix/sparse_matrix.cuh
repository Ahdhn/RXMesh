#include <iostream>
#include <vector>
#include "rxmesh/attribute.h"
#include "rxmesh/context.h"
#include "rxmesh/kernels/query_dispatcher.cuh"
#include "rxmesh/types.h"

#include "tinymatwriter.h"

namespace rxmesh {

namespace detail {
void patch_ptr_init(RXMeshStatic& rx,
                    uint32_t*&    d_vertex,
                    uint32_t*&    d_edge,
                    uint32_t*&    d_face)
{

    uint32_t num_patches = rx.get_num_patches();

    CUDA_ERROR(
        cudaMalloc((void**)&d_vertex, (num_patches + 1) * sizeof(uint32_t)));
    CUDA_ERROR(
        cudaMalloc((void**)&d_edge, (num_patches + 1) * sizeof(uint32_t)));
    CUDA_ERROR(
        cudaMalloc((void**)&d_face, (num_patches + 1) * sizeof(uint32_t)));

    CUDA_ERROR(cudaMemset(d_vertex, 0, (num_patches + 1) * sizeof(uint32_t)));
    CUDA_ERROR(cudaMemset(d_edge, 0, (num_patches + 1) * sizeof(uint32_t)));
    CUDA_ERROR(cudaMemset(d_face, 0, (num_patches + 1) * sizeof(uint32_t)));

    Context context = rx.get_context();

    // We kind "hack" for_each_vertex to store the owned vertex/edge/face
    // count in d_vertex/edge/face. Since in for_each_vertex we lunch
    // one block per patch, then blockIdx.x correspond to the patch id. We
    // then use only one thread from the block to write the owned
    // vertex/edge/face count
    rx.for_each_vertex(DEVICE, [=] __device__(const VertexHandle vh) {
        if (threadIdx.x == 0) {
            uint32_t patch_id = blockIdx.x;
            d_vertex[patch_id] =
                context.get_patches_info()[patch_id].num_owned_vertices;

            d_edge[patch_id] =
                context.get_patches_info()[patch_id].num_owned_edges;

            d_face[patch_id] =
                context.get_patches_info()[patch_id].num_owned_faces;
        }
    });

    CUDA_ERROR(cudaDeviceSynchronize());

    // Exclusive perfix sum computation. Increase the size by 1 so that we dont
    // need to stick in the total number of owned vertices/edges/faces at the
    // end of manually
    void*  d_cub_temp_storage = nullptr;
    size_t temp_storage_bytes = 0;
    cub::DeviceScan::ExclusiveSum(d_cub_temp_storage,
                                  temp_storage_bytes,
                                  d_vertex,
                                  d_vertex,
                                  num_patches + 1);
    CUDA_ERROR(cudaMalloc((void**)&d_cub_temp_storage, temp_storage_bytes));

    cub::DeviceScan::ExclusiveSum(d_cub_temp_storage,
                                  temp_storage_bytes,
                                  d_vertex,
                                  d_vertex,
                                  num_patches + 1);
    CUDA_ERROR(cudaMemset(d_cub_temp_storage, 0, temp_storage_bytes));

    cub::DeviceScan::ExclusiveSum(d_cub_temp_storage,
                                  temp_storage_bytes,
                                  d_edge,
                                  d_edge,
                                  num_patches + 1);
    CUDA_ERROR(cudaMemset(d_cub_temp_storage, 0, temp_storage_bytes));


    cub::DeviceScan::ExclusiveSum(d_cub_temp_storage,
                                  temp_storage_bytes,
                                  d_face,
                                  d_face,
                                  num_patches + 1);

    CUDA_ERROR(cudaFree(d_cub_temp_storage));
}

// this is the function for the CSR calculation
template <uint32_t blockThreads>
__global__ static void sparse_mat_prescan(const rxmesh::Context context,
                                          uint32_t*             patch_ptr_v,
                                          uint32_t*             row_ptr)
{
    using namespace rxmesh;

    auto init_lambda = [&](VertexHandle& v_id, const VertexIterator& iter) {
        auto     ids                              = v_id.unpack();
        uint32_t patch_id                         = ids.first;
        uint16_t local_id                         = ids.second;
        row_ptr[patch_ptr_v[patch_id] + local_id] = iter.size() + 1;
    };

    query_block_dispatcher<Op::VV, blockThreads>(context, init_lambda);
}

template <uint32_t blockThreads>
__global__ static void sparse_mat_col_fill(const rxmesh::Context context,
                                           uint32_t*             patch_ptr_v,
                                           uint32_t*             row_ptr,
                                           uint32_t*             col_idx)
{
    using namespace rxmesh;

    auto init_lambda = [&](VertexHandle& v_id, const VertexIterator& iter) {
        auto     ids      = v_id.unpack();
        uint32_t patch_id = ids.first;
        uint16_t local_id = ids.second;
        col_idx[row_ptr[patch_ptr_v[patch_id] + local_id]] =
            patch_ptr_v[patch_id] + local_id;
        for (uint32_t v = 0; v < iter.size(); ++v) {
            auto     s_ids      = iter[v].unpack();
            uint32_t s_patch_id = s_ids.first;
            uint16_t s_local_id = s_ids.second;
            col_idx[row_ptr[patch_ptr_v[patch_id] + local_id] + v + 1] =
                patch_ptr_v[s_patch_id] + s_local_id;
        }
    };

    query_block_dispatcher<Op::VV, blockThreads>(context, init_lambda);
}

// Follow the idea of "All calculations and storage is done on the GPU." This is
// for initial mem allocation. This is currently VV implementation, will bge
// extended
template <typename T>
void sparse_mat_init(RXMeshStatic& rx,
                     uint32_t*&    patch_ptr_v,
                     uint32_t*&    row_ptr,
                     uint32_t*&    col_idx,
                     uint32_t&     entry_size,
                     T*&           val)
{
    using namespace rxmesh;
    constexpr uint32_t blockThreads = 256;

    uint32_t num_patches  = rx.get_num_patches();
    uint32_t num_vertices = rx.get_num_vertices();
    uint32_t num_edges    = rx.get_num_edges();

    // row pointer allocation and init with prefix sum for CRS
    CUDA_ERROR(
        cudaMalloc((void**)&row_ptr, (num_vertices + 1) * sizeof(uint32_t)));

    CUDA_ERROR(cudaMemset(row_ptr, 0, (num_vertices + 1) * sizeof(uint32_t)));

    LaunchBox<blockThreads> launch_box;
    rx.prepare_launch_box(
        {Op::VV}, launch_box, (void*)sparse_mat_prescan<blockThreads>);

    sparse_mat_prescan<blockThreads>
        <<<launch_box.blocks,
           launch_box.num_threads,
           launch_box.smem_bytes_dyn>>>(rx.get_context(), patch_ptr_v, row_ptr);

    // prefix sum using CUB.
    void*  d_cub_temp_storage = nullptr;
    size_t temp_storage_bytes = 0;
    cub::DeviceScan::ExclusiveSum(d_cub_temp_storage,
                                  temp_storage_bytes,
                                  row_ptr,
                                  row_ptr,
                                  num_vertices + 1);
    CUDA_ERROR(cudaMalloc((void**)&d_cub_temp_storage, temp_storage_bytes));

    cub::DeviceScan::ExclusiveSum(d_cub_temp_storage,
                                  temp_storage_bytes,
                                  row_ptr,
                                  row_ptr,
                                  num_vertices + 1);

    CUDA_ERROR(cudaFree(d_cub_temp_storage));

    // get entry size
    CUDA_ERROR(cudaMemcpy(&entry_size,
                          (row_ptr + num_vertices),
                          sizeof(uint32_t),
                          cudaMemcpyDeviceToHost));

    // printf("%" PRIu32 " - %" PRIu32 " \n", entry_size, 2 * num_edges +
    // num_vertices);

    // column index allocation and init
    CUDA_ERROR(cudaMalloc((void**)&col_idx, entry_size * sizeof(uint32_t)));
    rx.prepare_launch_box(
        {Op::VV}, launch_box, (void*)sparse_mat_col_fill<blockThreads>);

    sparse_mat_col_fill<blockThreads><<<launch_box.blocks,
                                        launch_box.num_threads,
                                        launch_box.smem_bytes_dyn>>>(
        rx.get_context(), patch_ptr_v, row_ptr, col_idx);

    // val pointer allocation, actual value init should be in another function
    CUDA_ERROR(cudaMalloc((void**)&val, entry_size * sizeof(uint32_t)));
}
}  // namespace detail


// TODO: add compatibility for EE, FF, VE......
template <typename T>
struct SparseMatInfo
{
    SparseMatInfo(RXMeshStatic& rx)
        : m_d_patch_ptr_v(nullptr),
          m_d_patch_ptr_e(nullptr),
          m_d_patch_ptr_f(nullptr),
          m_d_row_ptr(nullptr),
          m_d_col_idx(nullptr),
          m_d_val(nullptr),
          m_nnz_entry_size(0)
    {
        m_num_rows = rx.get_num_vertices();
        detail::patch_ptr_init(rx,
                               m_d_patch_ptr_v,
                               m_d_patch_ptr_e,
                               m_d_patch_ptr_f);  // patch pointer init
        detail::sparse_mat_init(rx,
                                m_d_patch_ptr_v,
                                m_d_row_ptr,
                                m_d_col_idx,
                                m_nnz_entry_size,
                                m_d_val);
    }

    void set_ones()
    {
        std::vector<T> init_tmp_arr(m_nnz_entry_size, 1);
        CUDA_ERROR(cudaMemcpy(m_d_val,
                              init_tmp_arr.data(),
                              m_nnz_entry_size * sizeof(T),
                              cudaMemcpyHostToDevice));
    }

    void free()
    {
        CUDA_ERROR(cudaFree(m_d_patch_ptr_v));
        CUDA_ERROR(cudaFree(m_d_patch_ptr_e));
        CUDA_ERROR(cudaFree(m_d_patch_ptr_f));
        CUDA_ERROR(cudaFree(m_d_row_ptr));
        CUDA_ERROR(cudaFree(m_d_col_idx));
        CUDA_ERROR(cudaFree(m_d_val));
    }

    void writeMAT(std::string filename)
    {
        TinyMATWriterFile*    file = TinyMATWriter_open(filename.c_str());
        std::vector<uint32_t> h_row_ptr(m_num_rows + 1);
        std::vector<uint32_t> h_col_idx(m_nnz_entry_size);
        std::vector<T>        h_val(m_nnz_entry_size);
        CUDA_ERROR(cudaMemcpy(h_row_ptr.data(),
                              m_d_row_ptr,
                              (m_num_rows + 1) * sizeof(uint32_t),
                              cudaMemcpyDeviceToHost));
        CUDA_ERROR(cudaMemcpy(h_col_idx.data(),
                              m_d_col_idx,
                              m_nnz_entry_size * sizeof(uint32_t),
                              cudaMemcpyDeviceToHost));
        CUDA_ERROR(cudaMemcpy(h_val.data(),
                              m_d_val,
                              m_nnz_entry_size * sizeof(T),
                              cudaMemcpyDeviceToHost));
        std::vector<double> mat(m_num_rows * m_num_rows, 0);
        for (uint32_t r = 0; r < m_num_rows; ++r) {
            for (int i = h_row_ptr[r]; i < h_row_ptr[r + 1]; i++) {
                uint32_t c              = h_col_idx[i];
                mat[r * m_num_rows + c] = -1.0 * double(h_val[i]);
            }
            mat[r * m_num_rows + r] = 10.0;
        }
        TinyMATWriter_writeMatrix2D_rowmajor(
            file, "matirxXx", mat.data(), m_num_rows, m_num_rows);
        TinyMATWriter_close(file);
    }

    uint32_t *m_d_patch_ptr_v, *m_d_patch_ptr_e, *m_d_patch_ptr_f;
    uint32_t* m_d_row_ptr;
    uint32_t* m_d_col_idx;
    T*        m_d_val;
    uint32_t  m_nnz_entry_size;
    uint32_t  m_num_rows;
};

}  // namespace rxmesh