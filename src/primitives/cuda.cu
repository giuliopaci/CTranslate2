#include "ctranslate2/primitives/primitives.h"

#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <thrust/device_vector.h>
#include <thrust/iterator/discard_iterator.h>
#include <thrust/iterator/transform_output_iterator.h>
#include <cub/util_allocator.cuh>

#include "ctranslate2/types.h"
#include "../cuda/utils.h"

namespace ctranslate2 {

  template <typename T, typename UnaryFunction>
  void unary_transform(const T* x, T* y, size_t size, UnaryFunction op) {
    THRUST_CALL(thrust::transform, x, x + size, y, op);
  }

  template <typename T, typename BinaryFunction>
  void binary_transform(const T* a, const T* b, T* c, size_t size, BinaryFunction op) {
    THRUST_CALL(thrust::transform, a, a + size, b, c, op);
  }

  template <typename T1, typename T2, typename T3, typename BinaryFunction, typename IndexFunction>
  void binary_transform(T1 a, T2 b, T3 c, size_t size,
                        BinaryFunction op, IndexFunction index_a) {
    auto index_it = thrust::make_transform_iterator(thrust::counting_iterator<size_t>(0), index_a);
    auto a_it = thrust::make_permutation_iterator(a, index_it);
    THRUST_CALL(thrust::transform, a_it, a_it + size, b, c, op);
  }

  // perm_fun is a functor that takes the index in the permuted iterator and
  // return the index in the original iterator.
  template <typename T, typename PermFunction>
  void permute(const T* x, T* y, size_t size, PermFunction perm_fun) {
    auto ind_it = thrust::counting_iterator<size_t>(0);
    auto perm_ind_it = thrust::make_transform_iterator(ind_it, perm_fun);
    auto perm_it = thrust::make_permutation_iterator(x, perm_ind_it);
    THRUST_CALL(thrust::copy_n, perm_it, size, y);
  }


  // See https://nvlabs.github.io/cub/structcub_1_1_caching_device_allocator.html.
  static cub::CachingDeviceAllocator allocator(
    /*bin_growth=*/4,
    /*min_bin=*/3,
    /*max_bin=*/12,
    /*max_cached_bytes=*/200 * (1 << 20));

  template<>
  void primitives<Device::CUDA>::set_device(int index) {
    CUDA_CHECK(cudaSetDevice(index));
  }

  template<>
  int primitives<Device::CUDA>::get_device() {
    int index;
    CUDA_CHECK(cudaGetDevice(&index));
    return index;
  }

  template<>
  void* primitives<Device::CUDA>::alloc_data(size_t size) {
    void* data = nullptr;
    CUDA_CHECK(allocator.DeviceAllocate(&data, size, cuda::get_cuda_stream()));
    return data;
  }

  template<>
  void primitives<Device::CUDA>::free_data(void* data) {
    CUDA_CHECK(allocator.DeviceFree(data));
  }

  template<>
  void primitives<Device::CUDA>::clear_cache() {
    CUDA_CHECK(allocator.FreeAllCached());
  }

  template<>
  template <typename T>
  T primitives<Device::CUDA>::deref(const T* x, size_t index) {
    T val = T();
    cross_device_primitives<Device::CUDA, Device::CPU>::copy(x + index, &val, 1);
    return val;
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::fill(T* x, T a, size_t size) {
    THRUST_CALL(thrust::fill_n, x, size, a);
  }
  template<>
  template <typename T>
  void primitives<Device::CUDA>::strided_fill(T* x, T a, size_t inc_x, size_t size) {
    auto it = thrust::make_permutation_iterator(
      x, thrust::make_transform_iterator(thrust::counting_iterator<size_t>(0),
                                         thrust::placeholders::_1 * inc_x));
    THRUST_CALL(thrust::fill_n, it, size, a);
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::copy(const T* x, T* y, size_t size) {
    CUDA_CHECK(cudaMemcpyAsync(y, x, size * sizeof (T),
                               cudaMemcpyDeviceToDevice, cuda::get_cuda_stream()));
  }

  template<>
  template <typename T>
  T primitives<Device::CUDA>::sum(const T* array, size_t size) {
    return THRUST_CALL(thrust::reduce, array, array + size);
  }

  template<>
  template <typename T>
  size_t primitives<Device::CUDA>::max_element(const T* array, size_t size) {
    const auto* max = THRUST_CALL(thrust::max_element, array, array + size);
    return static_cast<size_t>(max - array);
  }

  template<>
  template <typename T>
  T primitives<Device::CUDA>::max(const T* array, size_t size) {
    const auto* max = THRUST_CALL(thrust::max_element, array, array + size);
    return deref(max, 0);
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::add(T a, const T* x, T* y, size_t size) {
    unary_transform(x, y, size, thrust::placeholders::_1 + a);
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::add(const T* a, const T* b, T* c, size_t size) {
    binary_transform(a, b, c, size, thrust::plus<T>());
  }

  template <typename T>
  struct repeat_vec : thrust::unary_function<T, T> {
    T _size;
    repeat_vec(T size)
      : _size(size) {
    }
    __host__ __device__
    T operator()(const T& i) {
      return i % _size;
    }
  };

  template <typename T>
  struct repeat_vec_depth : thrust::unary_function<T, T> {
    T _size;
    repeat_vec_depth(T size)
      : _size(size) {
    }
    __host__ __device__
    T operator()(const T& i) {
      return i / _size;
    }
  };

  template<>
  template <typename T>
  void primitives<Device::CUDA>::add_batch_broadcast(const T* a, const T* b, T* c,
                                                     size_t a_size, size_t b_size) {
    binary_transform(a, b, c, b_size, thrust::plus<T>(), repeat_vec<size_t>(a_size));
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::add_depth_broadcast(const T* a, const T* b, T* c,
                                                     size_t a_size, size_t b_size) {
    binary_transform(a, b, c, b_size, thrust::plus<T>(), repeat_vec_depth<size_t>(b_size / a_size));
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::sub(const T* a, const T* b, T* c, size_t size) {
    binary_transform(a, b, c, size, thrust::minus<T>());
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::mul(T a, const T* x, T* y, size_t size) {
    unary_transform(x, y, size, thrust::placeholders::_1 * a);
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::mul(const T* a, const T* b, T* c, size_t size) {
    binary_transform(a, b, c, size, thrust::multiplies<T>());
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::mul_batch_broadcast(const T* a, const T* b, T* c,
                                                     size_t a_size, size_t b_size) {
    binary_transform(a, b, c, b_size, thrust::multiplies<T>(), repeat_vec<size_t>(a_size));
  }

  template <typename T>
  struct wxpb_func : public thrust::binary_function<thrust::tuple<T, T>, T, T> {
    __host__ __device__
    T operator()(const thrust::tuple<T, T>& w_b, T x) {
      return thrust::get<0>(w_b) * x + thrust::get<1>(w_b);
    }
  };

  template<>
  template <typename T>
  void primitives<Device::CUDA>::mul_and_add_batch_broadcast(const T* x, const T* w, const T* b,
                                                             T* y, size_t x_size, size_t wb_size) {
    auto w_b = thrust::make_zip_iterator(thrust::make_tuple(w, b));
    binary_transform(w_b, x, y, x_size, wxpb_func<T>(), repeat_vec<size_t>(wb_size));
  }

  struct absolute_maximum_func : public thrust::binary_function<float, float, float> {
    __host__ __device__
    float operator()(float a, float b) {
      return fmaxf(fabsf(a), fabsf(b));
    }
  };

  template <typename T>
  struct quantize_func : public thrust::binary_function<float, float, T> {
    __host__ __device__
    T operator()(float scale, float x) {
      return static_cast<T>(x * scale);
    }
  };

  template<>
  void primitives<Device::CUDA>::quantize_batch(const float* x, float* scales, int8_t* qx,
                                                size_t batch_size, size_t depth) {
    size_t size = batch_size * depth;

    // Assign 1 key per batch.
    auto keys_it = thrust::make_transform_iterator(thrust::counting_iterator<int>(0),
                                                   repeat_vec_depth<int>(depth));

    // scales = 127.0 / reduce_max(abs(x), axis=1)
    THRUST_CALL(thrust::reduce_by_key,
                keys_it, keys_it + size,
                x,
                thrust::make_discard_iterator(),
                thrust::make_transform_output_iterator(
                  scales, static_cast<float>(127) / thrust::placeholders::_1),
                thrust::equal_to<int>(),
                absolute_maximum_func());

    // qx = x * expand_dims(scales, 1)
    binary_transform(scales, x, qx, size,
                     quantize_func<int8_t>(),
                     repeat_vec_depth<size_t>(depth));
  }

  template <typename T>
  struct unquantize_func : public thrust::binary_function<float, T, float> {
    __device__
    float operator()(float scale, T x) {
      return __fdividef(static_cast<float>(x), scale);
    }
  };

  template<>
  template<>
  void primitives<Device::CUDA>::unquantize_batch(const int8_t* x, const float* scale, float* y,
                                                  size_t x_size, size_t scale_size) {
    binary_transform(scale, x, y, x_size,
                     unquantize_func<int8_t>(),
                     repeat_vec_depth<size_t>(x_size / scale_size));
  }

  struct rescale_func : public thrust::binary_function<int32_t, thrust::tuple<float, float>, float> {
    __device__
    float operator()(int32_t x, const thrust::tuple<float, float>& scales) {
      return __fdividef(__int2float_rn(x), (thrust::get<0>(scales) * thrust::get<1>(scales)));
    }
  };

  template<>
  void primitives<Device::CUDA>::rescale_output(const int32_t* x,
                                                const float* input_scales,
                                                const float* weight_scales,
                                                float* y,
                                                size_t batch_size,
                                                size_t depth) {
    size_t size = batch_size * depth;

    // y = x / (expand_dims(input_scales, 1) * expand_dims(weight_scales, 0)
    auto input_scales_it = thrust::make_permutation_iterator(
      input_scales,
      thrust::make_transform_iterator(thrust::counting_iterator<int>(0),
                                      repeat_vec_depth<int>(depth)));
    auto weight_scales_it = thrust::make_permutation_iterator(
      weight_scales,
      thrust::make_transform_iterator(thrust::counting_iterator<int>(0),
                                      repeat_vec<int>(depth)));

    auto scales_it = thrust::make_zip_iterator(thrust::make_tuple(input_scales_it, weight_scales_it));
    THRUST_CALL(thrust::transform,
                x, x + size,
                scales_it,
                y,
                rescale_func());
  }

  struct relu_func : public thrust::unary_function<float, float> {
    __host__ __device__
    float operator()(float x) { return fmaxf(x, 0); }
  };

  template<>
  void primitives<Device::CUDA>::relu(const float* x, float* y, size_t size) {
    unary_transform(x, y, size, relu_func());
  }

  template <typename T>
  struct perm_indices_2d : public thrust::unary_function<T, T> {
    T _rows, _cols;
    perm_indices_2d(T rows, T cols)
      : _rows(rows)
      , _cols(cols) {
    }
    __host__ __device__
    T operator()(const T& i) const {
      const T i0 = i / _rows;
      const T i1 = i % _rows;
      return i1 * _cols + i0;
    }
  };

  template<>
  template <typename DataType, typename IndexType>
  void primitives<Device::CUDA>::transpose_2d(const DataType* a, const IndexType* dims, DataType* b) {
    permute(a, b, dims[0] * dims[1], perm_indices_2d<IndexType>(dims[0], dims[1]));
  }

  template <typename T>
  struct perm_indices_3d : public thrust::unary_function<T, T> {
    T _a_ps0, _a_ps1, _a_ps2; // Permuted strides of the original array.
    T _b_d0, _b_d1, _b_d2;    // Dimension of the permutated array.
    T _b_s0, _b_s1, _b_s2;    // Strides of the permutated array.
    perm_indices_3d(const T* dims, const T* perm) {
      const size_t a_stride[3] = {dims[1] * dims[2], dims[2], 1};
      _a_ps0 = a_stride[perm[0]];
      _a_ps1 = a_stride[perm[1]];
      _a_ps2 = a_stride[perm[2]];
      _b_d0 = dims[perm[0]];
      _b_d1 = dims[perm[1]];
      _b_d2 = dims[perm[2]];
      _b_s0 = _b_d1 * _b_d2;
      _b_s1 = _b_d2;
      _b_s2 = 1;
    }
    __host__ __device__
    T operator()(const T& i) const {
      const T i0 = i / _b_s0;
      const T i1 = i / _b_s1 % _b_d1;
      const T i2 = i % _b_d2;
      return i0 * _a_ps0 + i1 * _a_ps1 + i2 * _a_ps2;
    }
  };

  template<>
  template <typename DataType, typename IndexType>
  void primitives<Device::CUDA>::transpose_3d(const DataType* a,
                                              const IndexType* dims,
                                              const IndexType* perm,
                                              DataType* b) {
    permute(a, b, dims[0] * dims[1] * dims[2], perm_indices_3d<IndexType>(dims, perm));
  }

  template <typename T>
  struct perm_indices_4d : public thrust::unary_function<T, T> {
    T _a_ps0, _a_ps1, _a_ps2, _a_ps3; // Permuted strides of the original array.
    T _b_d0, _b_d1, _b_d2, _b_d3;    // Dimension of the permutated array.
    T _b_s0, _b_s1, _b_s2, _b_s3;    // Strides of the permutated array.
    perm_indices_4d(const T* dims, const T* perm) {
      const size_t a_stride[4] = {dims[1] * dims[2] * dims[3], dims[2] * dims[3], dims[3], 1};
      _a_ps0 = a_stride[perm[0]];
      _a_ps1 = a_stride[perm[1]];
      _a_ps2 = a_stride[perm[2]];
      _a_ps3 = a_stride[perm[3]];
      _b_d0 = dims[perm[0]];
      _b_d1 = dims[perm[1]];
      _b_d2 = dims[perm[2]];
      _b_d3 = dims[perm[3]];
      _b_s0 = _b_d1 * _b_d2 * _b_d3;
      _b_s1 = _b_d2 * _b_d3;
      _b_s2 = _b_d3;
      _b_s3 = 1;
    }
    __host__ __device__
    T operator()(const T& i) const {
      const T i0 = i / _b_s0;
      const T i1 = i / _b_s1 % _b_d1;
      const T i2 = i / _b_s2 % _b_d2;
      const T i3 = i % _b_d3;
      return i0 * _a_ps0 + i1 * _a_ps1 + i2 * _a_ps2 + i3 * _a_ps3;
    }
  };

  template<>
  template <typename DataType, typename IndexType>
  void primitives<Device::CUDA>::transpose_4d(const DataType* a,
                                              const IndexType* dims,
                                              const IndexType* perm,
                                              DataType* b) {
    permute(a, b, dims[0] * dims[1] * dims[2] * dims[3], perm_indices_4d<IndexType>(dims, perm));
  }

  template<>
  template<>
  void primitives<Device::CUDA>::gemm(const float* a, const float* b,
                                      bool transpose_a, bool transpose_b,
                                      size_t m, size_t n, size_t k,
                                      float alpha, float beta,
                                      float* c) {
    // Memo: cuBLAS assumes column-major storage.

    const int lda = transpose_a ? m : k;
    const int ldb = transpose_b ? k : n;
    const int ldc = n;

    const cublasOperation_t transa = transpose_a ? CUBLAS_OP_T : CUBLAS_OP_N;
    const cublasOperation_t transb = transpose_b ? CUBLAS_OP_T : CUBLAS_OP_N;

    CUBLAS_CHECK(cublasSgemm(cuda::get_cublas_handle(),
                             transb, transa,
                             n, m, k,
                             &alpha,
                             b, ldb,
                             a, lda,
                             &beta,
                             c, ldc));
  }

  template<>
  template<>
  void primitives<Device::CUDA>::gemm(const int8_t* a, const int8_t* b,
                                      bool transpose_a, bool transpose_b,
                                      size_t m, size_t n, size_t k,
                                      float alpha, float beta,
                                      int32_t* c) {
    const int lda = transpose_a ? m : k;
    const int ldb = transpose_b ? k : n;
    const int ldc = n;

    const cublasOperation_t transa = transpose_a ? CUBLAS_OP_T : CUBLAS_OP_N;
    const cublasOperation_t transb = transpose_b ? CUBLAS_OP_T : CUBLAS_OP_N;

    int32_t alpha_i = alpha;
    int32_t beta_i = beta;

    // cuBLAS assumes column-major storage, so swap a and b accordingly.
    CUBLAS_CHECK(cublasGemmEx(cuda::get_cublas_handle(),
                              transb, transa,
                              n, m, k,
                              &alpha_i,
                              b, CUDA_R_8I, ldb,
                              a, CUDA_R_8I, lda,
                              &beta_i,
                              c, CUDA_R_32I, ldc,
                              CUDA_R_32I,
                              CUBLAS_GEMM_DEFAULT_TENSOR_OP));
  }

  template<>
  template<>
  void primitives<Device::CUDA>::gemm_batch(const float* a, const float* b,
                                            bool transpose_a, bool transpose_b,
                                            size_t batch_size,
                                            size_t m, size_t n, size_t k,
                                            float alpha, float beta,
                                            float* c) {
    // Memo: cuBLAS assumes column-major storage.

    const int lda = transpose_a ? m : k;
    const int ldb = transpose_b ? k : n;
    const int ldc = n;

    const long long int stridea = m * k;
    const long long int strideb = k * n;
    const long long int stridec = m * n;

    const cublasOperation_t transa = transpose_a ? CUBLAS_OP_T : CUBLAS_OP_N;
    const cublasOperation_t transb = transpose_b ? CUBLAS_OP_T : CUBLAS_OP_N;

    CUBLAS_CHECK(cublasSgemmStridedBatched(cuda::get_cublas_handle(),
                                           transb, transa,
                                           n, m, k,
                                           &alpha,
                                           b, ldb, strideb,
                                           a, lda, stridea,
                                           &beta,
                                           c, ldc, stridec,
                                           batch_size));
  }

  struct exp_func : public thrust::unary_function<float, float> {
    __host__ __device__
    float operator()(float x) { return expf(x); }
  };

  template<>
  void primitives<Device::CUDA>::exp(const float* x, float* y, size_t size) {
    unary_transform(x, y, size, exp_func());
  }

  struct log_func : public thrust::unary_function<float, float> {
    __host__ __device__
    float operator()(float x) { return logf(x); }
  };

  template<>
  void primitives<Device::CUDA>::log(const float* x, float* y, size_t size) {
    unary_transform(x, y, size, log_func());
  }

  struct pow_func : public thrust::unary_function<float, float> {
    float _power;
    pow_func(float power)
      : _power(power) {
    }
    __host__ __device__
    float operator()(float x) { return powf(x, _power); }
  };

  template<>
  void primitives<Device::CUDA>::pow(const float* x, float* y, float power, size_t size) {
    unary_transform(x, y, size, pow_func(power));
  }


  template<>
  template <typename T>
  void cross_device_primitives<Device::CPU, Device::CUDA>::copy(const T* x, T* y, size_t size) {
    CUDA_CHECK(cudaMemcpyAsync(y, x, size * sizeof (T), cudaMemcpyHostToDevice, cuda::get_cuda_stream()));
  }

  template<>
  template <typename T>
  void cross_device_primitives<Device::CUDA, Device::CPU>::copy(const T* x, T* y, size_t size) {
    CUDA_CHECK(cudaMemcpyAsync(y, x, size * sizeof (T), cudaMemcpyDeviceToHost, cuda::get_cuda_stream()));
  }

#define DECLARE_IMPL(T)                                                 \
  template T                                                            \
  primitives<Device::CUDA>::deref(const T* x, size_t index);            \
  template void                                                         \
  primitives<Device::CUDA>::fill(T* x, T a, size_t size);               \
  template void                                                         \
  primitives<Device::CUDA>::strided_fill(T* x, T a, size_t inc_x, size_t size); \
  template void                                                         \
  primitives<Device::CUDA>::copy<T>(const T* x, T* y, size_t size);     \
  template T                                                            \
  primitives<Device::CUDA>::sum(const T* array, size_t size);           \
  template size_t                                                       \
  primitives<Device::CUDA>::max_element(const T* array, size_t size);   \
  template T                                                            \
  primitives<Device::CUDA>::max(const T* array, size_t size);           \
  template void                                                         \
  primitives<Device::CUDA>::add(T a, const T* x, T* y, size_t size);    \
  template void                                                         \
  primitives<Device::CUDA>::add(const T* a, const T* b, T* c, size_t size); \
  template void                                                         \
  primitives<Device::CUDA>::add_batch_broadcast(const T* a, const T* b, \
                                                T* c, size_t a_size, size_t b_size); \
  template void                                                         \
  primitives<Device::CUDA>::add_depth_broadcast(const T* a, const T* b, \
                                                T* c, size_t a_size, size_t b_size); \
  template void                                                         \
  primitives<Device::CUDA>::sub(const T* a, const T* b, T* c, size_t size); \
  template void                                                         \
  primitives<Device::CUDA>::mul(T a, const T* x, T* y, size_t size);    \
  template void                                                         \
  primitives<Device::CUDA>::mul(const T* a, const T* b, T* c, size_t size); \
  template void                                                         \
  primitives<Device::CUDA>::mul_batch_broadcast(const T* a, const T* b, \
                                                T* c, size_t a_size, size_t b_size); \
  template void                                                         \
  primitives<Device::CUDA>::mul_and_add_batch_broadcast(const T* x, const T* w, const T* b, \
                                                        T* y, size_t x_size, size_t wb_size); \
  template void                                                         \
  primitives<Device::CUDA>::transpose_2d(const T* a, const size_t* dims, T* b); \
  template void                                                         \
  primitives<Device::CUDA>::transpose_3d(const T* a,                    \
                                         const size_t* dims,            \
                                         const size_t* perm,            \
                                         T* b);                         \
  template void                                                         \
  primitives<Device::CUDA>::transpose_4d(const T* a,                    \
                                         const size_t* dims,            \
                                         const size_t* perm,            \
                                         T* b);                         \
  template void                                                         \
  cross_device_primitives<Device::CPU, Device::CUDA>::copy<T>(const T*, T*, size_t); \
  template void                                                         \
  cross_device_primitives<Device::CUDA, Device::CPU>::copy<T>(const T*, T*, size_t);

  DECLARE_ALL_TYPES(DECLARE_IMPL)

}
