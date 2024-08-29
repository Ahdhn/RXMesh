#include "gtest/gtest.h"

#include <filesystem>

#include "rxmesh/rxmesh_static.h"

#include "rxmesh/matrix/mgnd_permute.cuh"
#include "rxmesh/matrix/nd_reorder.cuh"
#include "rxmesh/matrix/permute_util.h"
#include "rxmesh/matrix/sparse_matrix.cuh"

#include "count_nnz_fillin.h"

#include "metis.h"

struct arg
{
    std::string obj_file_name = STRINGIFY(INPUT_DIR) "cube.obj";
    uint16_t    nd_level      = 4;
    uint32_t    device_id     = 0;
} Arg;

template <typename EigeMatT>
void no_permute(const EigeMatT& eigen_mat)
{
    using namespace rxmesh;

    std::vector<int> h_permute(eigen_mat.rows());

    fill_with_sequential_numbers(h_permute.data(), h_permute.size());

    int nnz = count_nnz_fillin(eigen_mat, h_permute);

    RXMESH_INFO(" No-permutation NNZ = {}", nnz);
}

template <typename T, typename EigeMatT>
void with_metis(const rxmesh::SparseMatrix<T>& rx_mat,
                const EigeMatT&                eigen_mat)
{
    EXPECT_TRUE(rx_mat.rows() == eigen_mat.rows());
    EXPECT_TRUE(rx_mat.cols() == eigen_mat.cols());
    EXPECT_TRUE(rx_mat.non_zeros() == eigen_mat.nonZeros());

    idx_t n = eigen_mat.rows();

    // xadj is of length n+1 marking the start of the adjancy list of each
    // vertex in adjncy.
    std::vector<idx_t> xadj(n + 1);

    // adjncy stores the adjacency lists of the vertices. The adjnacy list of a
    // vertex should not contain the vertex itself.
    std::vector<idx_t> adjncy;
    adjncy.reserve(eigen_mat.nonZeros());

    // populate xadj and adjncy
    xadj[0] = 0;
    for (int r = 0; r < rx_mat.rows(); ++r) {
        int start = rx_mat.row_ptr()[r];
        int stop  = rx_mat.row_ptr()[r + 1];
        for (int i = start; i < stop; ++i) {
            int c = rx_mat.col_idx()[i];
            if (r != c) {
                adjncy.push_back(c);
            }
        }
        xadj[r + 1] = adjncy.size();
    }

    // is an array of size n such that if A and A' are the original and
    // permuted matrices, then A'[i] = A[perm[i]].
    std::vector<idx_t> h_permute(n);

    // iperm is an array of size n such that if A and A' are the original
    // and permuted matrices, then A[i] = A'[iperm[i]].
    std::vector<idx_t> h_iperm(n);

    // Metis options
    idx_t options[METIS_NOPTIONS];
    METIS_SetDefaultOptions(options);


    /*// Specifies the partitioning method
    options[METIS_OPTION_PTYPE] = METIS_PTYPE_RB;

    // Specifies the type of objective
    options[METIS_OPTION_OBJTYPE] = METIS_OBJTYPE_NODE;

    // Specifies the matching scheme to be used during coarsening
    options[METIS_OPTION_CTYPE] = METIS_CTYPE_RM;

    // Determines the algorithm used during initial partitioning.
    options[METIS_OPTION_IPTYPE] = METIS_IPTYPE_EDGE;

    // Determines the algorithm used for refinement
    options[METIS_OPTION_RTYPE] = METIS_RTYPE_SEP1SIDED;*/

    // Used to indicate which numbering scheme is used for the adjacency
    // structure of a graph or the elementnode structure of a mesh.
    options[METIS_OPTION_NUMBERING] = 0;  // 0-based indexing

    /*// Specifies that the graph should be compressed by combining together
    // vertices that have identical adjacency lists.
    options[METIS_OPTION_COMPRESS] = 0;  // Does not try to compress the graph.

    // Specifies the amount of progress/debugging information will be printed
    options[METIS_OPTION_DBGLVL] = 0;*/


    METIS_NodeND(&n,
                 xadj.data(),
                 adjncy.data(),
                 NULL,
                 options,
                 h_permute.data(),
                 h_iperm.data());

    EXPECT_TRUE(
        rxmesh::is_unique_permutation(h_permute.size(), h_permute.data()));

    int nnz = count_nnz_fillin(eigen_mat, h_iperm);

    RXMESH_INFO(" With METIS Nested Dissection NNZ = {}", nnz);
}

template <typename EigeMatT>
void with_mgnd(const rxmesh::RXMeshStatic& rx, const EigeMatT& eigen_mat)
{
    std::vector<int> h_permute(eigen_mat.rows());

    rxmesh::mgnd_permute(rx, h_permute);

    EXPECT_TRUE(
        rxmesh::is_unique_permutation(h_permute.size(), h_permute.data()));

    int nnz = count_nnz_fillin(eigen_mat, h_permute);

    RXMESH_INFO(" With MGND NNZ = {}", nnz);
}

TEST(Apps, NDReorder)
{
    using namespace rxmesh;

    cuda_query(Arg.device_id);

    const std::string p_file = STRINGIFY(OUTPUT_DIR) +
                               extract_file_name(Arg.obj_file_name) +
                               "_patches";
    RXMeshStatic rx(Arg.obj_file_name, p_file);
    if (!std::filesystem::exists(p_file)) {
        rx.save(p_file);
    }

    // VV matrix
    rxmesh::SparseMatrix<float> rx_mat(rx);

    // populate an SPD matrix
    rx_mat.for_each([](int r, int c, float& val) {
        if (r == c) {
            val = 10.0f;
        } else {
            val = -1.0f;
        }
    });

    RXMESH_INFO(" Input Matrix NNZ = {}", rx_mat.non_zeros());

    // convert matrix to Eigen
    auto eigen_mat = rx_mat.to_eigen();

    no_permute(eigen_mat);

    with_metis(rx_mat, eigen_mat);

    with_mgnd(rx, eigen_mat);

    // cuda_nd_reorder(rx, h_reorder_array, Arg.nd_level);
}

int main(int argc, char** argv)
{
    using namespace rxmesh;
    Log::init();

    ::testing::InitGoogleTest(&argc, argv);

    if (argc > 1) {
        if (cmd_option_exists(argv, argc + argv, "-h")) {
            // clang-format off
            RXMESH_INFO("\nUsage: NDReorder.exe < -option X>\n"
                        " -h:          Display this massage and exits\n"
                        " -input:      Input file. Input file should under the input/ subdirectory\n"
                        "              Default is {} \n"
                        "              Hint: Only accepts OBJ files\n"                                              
                        " -device_id:  GPU device ID. Default is {}",
            Arg.obj_file_name,  Arg.device_id);
            // clang-format on
            exit(EXIT_SUCCESS);
        }

        if (cmd_option_exists(argv, argc + argv, "-input")) {
            Arg.obj_file_name =
                std::string(get_cmd_option(argv, argv + argc, "-input"));
        }

        if (cmd_option_exists(argv, argc + argv, "-device_id")) {
            Arg.device_id =
                atoi(get_cmd_option(argv, argv + argc, "-device_id"));
        }

        if (cmd_option_exists(argv, argc + argv, "-nd_level")) {
            Arg.nd_level = atoi(get_cmd_option(argv, argv + argc, "-nd_level"));
        }
    }

    RXMESH_TRACE("input= {}", Arg.obj_file_name);
    RXMESH_TRACE("device_id= {}", Arg.device_id);

    return RUN_ALL_TESTS();
}