#pragma once
#include <stdint.h>
#include "rxmesh/handle.h"
#include "rxmesh/lp_hashtable.cuh"
#include "rxmesh/patch_stash.cuh"
#include "rxmesh/util/bitmask_util.h"

namespace rxmesh {

template <typename HandleT>
struct Iterator
{
    using LocalT = typename HandleT::LocalT;

    __device__ Iterator(const uint16_t     local_id,
                        const LocalT*      patch_output,
                        const uint16_t*    patch_offset,
                        const uint32_t     offset_size,
                        const uint32_t     patch_id,
                        const uint32_t*    output_owned_bitmask,
                        const LPHashTable& output_lp_hashtable,
                        const LPPair*      s_table,
                        const PatchStash   patch_stash,
                        int                shift = 0)
        : m_patch_output(patch_output),
          m_patch_id(patch_id),
          m_output_owned_bitmask(output_owned_bitmask),
          m_output_lp_hashtable(output_lp_hashtable),
          m_s_table(s_table),
          m_patch_stash(patch_stash),
          m_shift(shift)
    {
        set(local_id, offset_size, patch_offset);
    }

    Iterator(const Iterator& orig) = default;


    __device__ uint16_t size() const
    {
        return m_end - m_begin;
    }

    __device__ HandleT operator[](const uint16_t i) const
    {
        assert(m_patch_output);
        assert(i + m_begin < m_end);
        uint16_t lid = (m_patch_output[m_begin + i].id) >> m_shift;
        if (lid == INVALID16) {
            return HandleT();
        }
        if (detail::is_owned(lid, m_output_owned_bitmask)) {
            return {m_patch_id, lid};
        } else {
            LPPair lp = m_output_lp_hashtable.find(lid, m_s_table);
            return {m_patch_stash.get_patch(lp), lp.local_id_in_owner_patch()};
        }
    }

    __device__ HandleT operator*() const
    {
        assert(m_patch_output);
        return ((*this)[m_current]);
    }

    __device__ HandleT back() const
    {
        return ((*this)[size() - 1]);
    }

    __device__ HandleT front() const
    {
        return ((*this)[0]);
    }

    __device__ Iterator& operator++()
    {
        // pre
        m_current = (m_current + 1) % size();
        return *this;
    }
    __device__ Iterator operator++(int)
    {
        // post
        Iterator pre(*this);
        m_current = (m_current + 1) % size();
        return pre;
    }

    __device__ Iterator& operator--()
    {
        // pre
        m_current = (m_current == 0) ? size() - 1 : m_current - 1;
        return *this;
    }

    __device__ Iterator operator--(int)
    {
        // post
        Iterator pre(*this);
        m_current = (m_current == 0) ? size() - 1 : m_current - 1;
        return pre;
    }

    __device__ bool operator==(const Iterator& rhs) const
    {
        return rhs.m_local_id == m_local_id && rhs.m_patch_id == m_patch_id &&
               rhs.m_current == m_current;
    }

    __device__ bool operator!=(const Iterator& rhs) const
    {
        return !(*this == rhs);
    }


   private:
    uint16_t          m_local_id;
    const LocalT*     m_patch_output;
    const uint32_t    m_patch_id;
    const uint32_t*   m_output_owned_bitmask;
    const LPHashTable m_output_lp_hashtable;
    const LPPair*     m_s_table;
    PatchStash        m_patch_stash;
    uint16_t          m_begin;
    uint16_t          m_end;
    uint16_t          m_current;
    int               m_shift;

    __device__ void set(const uint16_t  local_id,
                        const uint32_t  offset_size,
                        const uint16_t* patch_offset)
    {
        m_current  = 0;
        m_local_id = local_id;
        if (offset_size == 0) {
            m_begin = patch_offset[m_local_id];
            m_end   = patch_offset[m_local_id + 1];
        } else {
            m_begin = m_local_id * offset_size;
            m_end   = (m_local_id + 1) * offset_size;
        }
        assert(m_end > m_begin);
    }
};

using VertexIterator = Iterator<VertexHandle>;
using EdgeIterator   = Iterator<EdgeHandle>;
using DEdgeIterator  = Iterator<DEdgeHandle>;
using FaceIterator   = Iterator<FaceHandle>;

}  // namespace rxmesh