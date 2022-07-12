#pragma once
#include <vector>
#include "rxmesh/util/report.h"


template <typename T>
inline void gaussian_curvature_ref(
    const std::vector<std::vector<uint32_t>>& Faces,
    const std::vector<std::vector<T>>&        Verts,
    std::vector<T>&                           gaussian_curvature)
{    
    uint32_t num_vertices = Verts.size();
    uint32_t num_faces    = Faces.size();

    std::vector<T> region_mixed(gaussian_curvature.size());

    std::fill(gaussian_curvature.begin(), gaussian_curvature.end(), 2 * PI);
    std::fill(region_mixed.begin(), region_mixed.end(), 0);

    T        edge_len_sq[3];
    T        angle_sin;
    T        angle_cos[3];
    T        rads[3];
    uint32_t v[3];
    T        fn[3];

    auto l2_norm_sq = [](const T ax0,
                         const T ax1,
                         const T ax2,
                         const T bx0,
                         const T bx1,
                         const T bx2) {
        // compute (xa0-xb0)*(xa0-xb0) + (xa1-xb1)*(xa1-xb1) +
        // (xa2-xb2)*(xa2-xb2)
        T x0 = ax0 - bx0;
        T x1 = ax1 - bx1;
        T x2 = ax2 - bx2;
        return (x0 * x0 + x1 * x1 + x2 * x2);
    };

    auto cross_product_norm = [](T xv1, T yv1, T zv1, T xv2, T yv2, T zv2) {
        T xx = yv1 * zv2 - zv1 * yv2;
        T yy = zv1 * xv2 - xv1 * zv2;
        T zz = xv1 * yv2 - yv1 * xv2;
        return sqrt(xx * xx + yy * yy + zz * zz);  // l2 norm
    };

    auto dot_product = [](T xv1, T yv1, T zv1, T xv2, T yv2, T zv2) {
        return xv1 * xv2 + yv1 * yv2 + zv1 * zv2;
    };

    for (uint32_t f = 0; f < num_faces; ++f) {
        v[0]       = Faces[f][0];
        v[1]       = Faces[f][1];
        v[2]       = Faces[f][2];
        bool is_ob = false;

        angle_sin = cross_product_norm(Verts[v[1]][0] - Verts[v[0]][0],
                                       Verts[v[1]][1] - Verts[v[0]][1],
                                       Verts[v[1]][2] - Verts[v[0]][2],
                                       Verts[v[2]][0] - Verts[v[0]][0],
                                       Verts[v[2]][1] - Verts[v[0]][1],
                                       Verts[v[2]][2] - Verts[v[0]][2]);

        for (uint32_t i = 0; i < 3; ++i) {
            uint32_t i1    = (i + 1) % 3;
            uint32_t i2    = (i + 2) % 3;
            angle_cos[i]   = dot_product(Verts[v[i1]][0] - Verts[v[i]][0],
                                       Verts[v[i1]][1] - Verts[v[i]][1],
                                       Verts[v[i1]][2] - Verts[v[i]][2],
                                       Verts[v[i2]][0] - Verts[v[i]][0],
                                       Verts[v[i2]][1] - Verts[v[i]][1],
                                       Verts[v[i2]][2] - Verts[v[i]][2]);
            edge_len_sq[i] = l2_norm_sq(Verts[v[i]][0],
                                        Verts[v[i]][1],
                                        Verts[v[i]][2],
                                        Verts[v[i1]][0],
                                        Verts[v[i1]][1],
                                        Verts[v[i1]][2]);
            rads[i]        = atan2(angle_sin, angle_cos[i]);
            if (rads[i] > PI * 0.5)
                is_ob = true;
        }

        for (uint32_t i = 0; i < 3; ++i) {
            uint32_t i1 = (i + 1) % 3;
            uint32_t i2 = (i + 2) % 3;

            if (is_ob) {
                if (rads[i] > PI * 0.5) {
                    region_mixed[v[i]] += 0.25 * angle_sin;
                } else {
                    region_mixed[v[i]] += 0.125 * angle_sin;
                }
            } else {
                // veronoi region calculation
                region_mixed[v[i]] +=
                    0.125 * ((edge_len_sq[i2]) * (angle_cos[i1] / angle_sin) +
                             (edge_len_sq[i]) * (angle_cos[i2] / angle_sin));
            }

            gaussian_curvature[v[i]] -= rads[i];
        }
    }

    for (uint32_t n = 0; n < num_vertices; ++n) {
        gaussian_curvature[n] = gaussian_curvature[n] / region_mixed[n];
    }
}
