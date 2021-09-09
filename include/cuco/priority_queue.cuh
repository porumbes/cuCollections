#pragma once

#include <vector>
#include <utility>
#include <cuco/detail/pq_pair.cuh>

namespace cuco {

/*
* @brief A GPU-accelerated priority queue of key-value pairs
*
* Allows for multiple concurrent insertions as well as multiple concurrent
* deletions
*
* Current limitations:
* - Only supports trivially comparable key types
* - Does not support insertion and deletion at the same time
*   - The implementation of the priority queue is based on 
*     https://arxiv.org/pdf/1906.06504.pdf, which provides a way to allow
*     concurrent insertion and deletion, so this could be added later if useful
* - Capacity is fixed and the queue does not automatically resize
* - Deletion from the queue is much slower than insertion into the queue
*   due to congestion at the underlying heap's root node
* 
* The queue supports two operations:
*   `push`: Add elements into the queue
*   `pop`: Remove the element(s) with the lowest (when Max == false) or highest
*        (when Max == true) keys
*
* The priority queue supports bulk host-side operations and more fine-grained
* device-side operations.
*
* The host-side bulk operations `push` and `pop` allow an arbitrary number of
* elements to be pushed to or popped from the queue.
*
* The device-side operations allow a cooperative group to push or pop
* some number of elements less than or equal to node_size. These device side
* operations are invoked with a trivially-copyable device view,
* `device_mutable_view` which can be obtained with the host function 
* `get_mutable_device_view` and passed to the device.
*
* @tparam Key Trivially comparable type used for keys
* @tparam Value Type of the value to be stored
* @tparam Max When false, pop operations yield the elements with the smallest
*             keys in the queue, otherwise, pop operations yeild the elements
*             with the largest keys
*/
template <typename Key, typename Value, bool Max = false>
class priority_queue {

 public:
  /**
   * @brief Construct a priority queue
   *
   * @param initial_capacity The number of elements the priority queue can hold
   * @param node_size The size of the nodes in the underlying heap data
   *        structure
   */
  priority_queue(size_t initial_capacity, size_t node_size = 1024);

  /**
   * @brief Push num_elements elements into the priority queue
   *
   * @param elements Array of elements to add to the queue
   * @param num_elements Number of elements to add to the queue
   * @param block_size Block size to use for the internal kernel launch
   * @param grid_size Grid size for the internal kernel launch
   * @param warp_size If true, each node is handled by a single warp, otherwise
   *                  by a single block
   * @param stream The stream in which the underlying GPU operations will be
   *               run
   */
  void push(Pair<Key, Value> *elements, size_t num_elements,
            int block_size = 256, int grid_size = 64000,
            bool warp_level = false,
            cudaStream_t stream = 0);

  /**
   * @brief Remove the num_elements elements with the lowest keys from the priority
   * queue and place them in out in ascending sorted order by key
   *
   * @param out The array in which the removed elements will be placed
   * @param num_elements The number of elements to be removed
   * @param block_size Block size to use for the internal kernel launch
   * @param grid_size Grid size for the internal kernel launch
   * @param warp_size If true, each node is handled by a single warp, otherwise
   *                  by a single block
   * @param stream The stream in which the underlying GPU operations will be
   *               run
   */
  void pop(Pair<Key, Value> *out, size_t num_elements,
           int block_size = 512, int grid_size = 32000,
           bool warp_level = false,
           cudaStream_t stream = 0);

  /*
  * @brief Return the amount of shared memory required for operations on the queue
  * with a thread block size of block_size
  *
  * @param block_size Size of the blocks to calculate storage for
  * @return The amount of temporary storage required in bytes
  */
  int get_shmem_size(int block_size) {
    int intersection_bytes = 2 * (block_size + 1) * sizeof(int);
    int node_bytes = node_size_ * sizeof(Pair<Key, Value>);
    return intersection_bytes + 2 * node_bytes;
  }

  /**
   * @brief Destroys the queue and frees its contents
   */
  ~priority_queue();

  class device_mutable_view {
   public:

    /**
     * @brief Push a single node or less elements into the priority queue
     *
     * @tparam CG Cooperative Group type
     * @param g The cooperative group that will perform the operation
     * @param elements Array of elements to add to the queue
     * @param num_elements Number of elements to add to the queue
     * @param Pointer to a contiguous section of memory large enough
     *        to hold get_shmem_size(g.size()) bytes
     */
    template <typename CG>
    __device__ void push(CG const& g, Pair<Key, Value> *elements,
                         size_t num_elements, void *temp_storage);

    /**
     * @brief Pop a single node or less elements from the priority queue
     *
     * @tparam CG Cooperative Group type
     * @param g The cooperative group that will perform the operation
     * @param out Array of elements to put the removed elements in 
     * @param num_elements Number of elements to remove from the queue
     * @param Pointer to a contiguous section of memory large enough
     *        to hold get_shmem_size(g.size()) bytes
     */
    template <typename CG>
    __device__ void pop(CG const& g, Pair<Key, Value> *out,
                        size_t num_elements, void *temp_storage);

    /**
     * @brief Returns the node size of the queue's underlying heap
     *        representation, i.e. the maximum number of elements
     *        pushable or poppable with a call to the device push
     *        and pop functions
     *
     * @return The underlying node size
     */
    __device__ size_t get_node_size() {
      return node_size_;
    }

    /*
    * @brief Return the amount of temporary storage required for operations
    * on the queue with a cooperative group size of block_size
    *
    * @param block_size Size of the cooperative groups to calculate storage for
    * @return The amount of temporary storage required in bytes
    */
    __device__ int get_shmem_size(int block_size) {
      int intersection_bytes = 2 * (block_size + 1) * sizeof(int);
      int node_bytes = node_size_ * sizeof(Pair<Key, Value>);
      return intersection_bytes + 2 * node_bytes;
    }

    __host__ __device__ device_mutable_view(size_t node_size,
                                            Pair<Key, Value> *d_heap,
                                            int *d_size,
                                            size_t *d_p_buffer_size,
                                            int *d_locks,
                                            int lowest_level_start,
                                            int node_capacity)
      : node_size_(node_size),
        d_heap_(d_heap),
        d_size_(d_size),
        d_p_buffer_size_(d_p_buffer_size),
        d_locks_(d_locks),
        lowest_level_start_(lowest_level_start),
        node_capacity_(node_capacity)
    {
    }

   private:
    size_t node_size_;
    int lowest_level_start_;
    int node_capacity_;

    Pair<Key, Value> *d_heap_;
    int *d_size_;
    size_t *d_p_buffer_size_;
    int *d_locks_;
  };

  /*
  * @brief Returns a trivailly-copyable class that can be used to perform 
  *        insertion and deletion of single nodes in device code with
  *        cooperative groups
  *
  * @return A device view
  */
  device_mutable_view get_mutable_device_view() {
    return device_mutable_view(node_size_, d_heap_, d_size_, d_p_buffer_size_,
                               d_locks_, lowest_level_start_, node_capacity_);
  }

 private:
  size_t node_size_;         ///< Size of the heap's nodes
  int lowest_level_start_;   ///< Index in `d_heap_` of the first node in the
                             ///  heap's lowest level
  int node_capacity_;        ///< Capacity of the heap in nodes

  Pair<Key, Value> *d_heap_; ///< Pointer to an array of nodes, the 0th node
                             ///  being the heap's partial buffer, and nodes
                             ///  1..(node_capacity_) being the heap, where the
                             ///  1st node is the root
  int *d_size_;              ///< Number of nodes currently in the heap
  size_t *d_p_buffer_size_;  ///< Number of elements currently in the partial
                             ///  buffer
  int *d_locks_;             ///< Array of locks where `d_locks_[i]` is the
                             ///  lock for the node starting at
                             ///  1d_heap_[node_size * i]`
  int *d_pop_tracker_;       ///< Variable used to track where in its output
                             ///  array a pop operation should place a given
                             ///  popped node
};

}

#include <cuco/detail/priority_queue.inl>
