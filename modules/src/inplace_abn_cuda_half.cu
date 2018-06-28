#include <ATen/ATen.h>

#include <cuda_fp16.h>

#include <vector>

#include "common.h"
#include "inplace_abn.h"

// Operations for reduce
struct SumOpH {
  __device__ SumOpH(const half *t, int c, int s)
      : tensor(t), chn(c), sp(s) {}
  __device__ __forceinline__ float operator()(int batch, int plane, int n) {
    return __half2float(tensor[(batch * chn + plane) * sp + n]);
  }
  const half *tensor;
  const int chn;
  const int sp;
};

struct VarOpH {
  __device__ VarOpH(float m, const half *t, int c, int s)
      : mean(m), tensor(t), chn(c), sp(s) {}
  __device__ __forceinline__ float operator()(int batch, int plane, int n) {
    const auto t = __half2float(tensor[(batch * chn + plane) * sp + n]);
    return (t - mean) * (t - mean);
  }
  const float mean;
  const half *tensor;
  const int chn;
  const int sp;
};


struct GradOp {
  __device__ GradOp(float _weight, float _bias, const half *_z, const half *_dz, int c, int s)
      : weight(_weight), bias(_bias), z(_z), dz(_dz), chn(c), sp(s) {}
  __device__ __forceinline__ Pair<float> operator()(int batch, int plane, int n) {
    float _y = (__half2float(z[(batch * chn + plane) * sp + n]) - bias) / weight;
    float _dz = __half2float(dz[(batch * chn + plane) * sp + n]);
    return Pair<float>(_dz, _y * _dz);
  }
  const float weight;
  const float bias;
  const half *z;
  const half *dz;
  const int chn;
  const int sp;
};

/***********
 * mean_var
 ***********/

__global__ void mean_var_kernel_h(const half *x, float *mean, float *var, int num, int chn, int sp) {
  int plane = blockIdx.x;
  float norm = 1.f / static_cast<float>(num * sp);

  float _mean = reduce<float, SumOpH>(SumOpH(x, chn, sp), plane, num, sp) * norm;
  __syncthreads();
  float _var = reduce<float, VarOpH>(VarOpH(_mean, x, chn, sp), plane, num, sp) * norm;

  if (threadIdx.x == 0) {
    mean[plane] = _mean;
    var[plane] = _var;
  }
}

std::vector<at::Tensor> mean_var_cuda_h(at::Tensor x) {
  CHECK_INPUT(x);

  // Extract dimensions
  int64_t num, chn, sp;
  get_dims(x, num, chn, sp);

  // Prepare output tensors
  auto mean = at::empty(x.type().toScalarType(at::kFloat), {chn});
  auto var = at::empty(x.type().toScalarType(at::kFloat), {chn});

  // Run kernel
  dim3 blocks(chn);
  dim3 threads(getNumThreads(sp));
  mean_var_kernel_h<<<blocks, threads>>>(
      reinterpret_cast<half*>(x.data<at::Half>()),
      mean.data<float>(),
      var.data<float>(),
      num, chn, sp);

  return {mean, var};
}

/**********
 * forward
 **********/

__global__ void forward_kernel_h(half *x, const float *mean, const float *var, const float *weight, const float *bias,
                                 bool affine, float eps, int num, int chn, int sp) {
  int plane = blockIdx.x;

  const float _mean = mean[plane];
  const float _var = var[plane];
  const float _weight = affine ? abs(weight[plane]) + eps : 1.f;
  const float _bias = affine ? bias[plane] : 0.f;

  const float mul = rsqrt(_var + eps) * _weight;

  for (int batch = 0; batch < num; ++batch) {
    for (int n = threadIdx.x; n < sp; n += blockDim.x) {
      half *x_ptr = x + (batch * chn + plane) * sp + n;
      float _x = __half2float(*x_ptr);
      float _y = (_x - _mean) * mul + _bias;

      *x_ptr = __float2half(_y);
    }
  }
}

at::Tensor forward_cuda_h(at::Tensor x, at::Tensor mean, at::Tensor var, at::Tensor weight, at::Tensor bias,
                        bool affine, float eps) {
  CHECK_INPUT(x);
  CHECK_INPUT(mean);
  CHECK_INPUT(var);
  CHECK_INPUT(weight);
  CHECK_INPUT(bias);

  // Extract dimensions
  int64_t num, chn, sp;
  get_dims(x, num, chn, sp);

  // Run kernel
  dim3 blocks(chn);
  dim3 threads(getNumThreads(sp));
  forward_kernel_h<<<blocks, threads>>>(
      reinterpret_cast<half*>(x.data<at::Half>()),
      mean.data<float>(),
      var.data<float>(),
      weight.data<float>(),
      bias.data<float>(),
      affine, eps, num, chn, sp);

  return x;
}

__global__ void edz_eydz_kernel_h(const half *z, const half *dz, const float *weight, const float *bias,
                                float *edz, float *eydz, bool affine, float eps, int num, int chn, int sp) {
  int plane = blockIdx.x;

  float _weight = affine ? abs(weight[plane]) + eps : 1.f;
  float _bias = affine ? bias[plane] : 0.f;

  Pair<float> res = reduce<Pair<float>, GradOp>(GradOp(_weight, _bias, z, dz, chn, sp), plane, num, sp);
  __syncthreads();

  if (threadIdx.x == 0) {
    edz[plane] = res.v1;
    eydz[plane] = res.v2;
  }
}

std::vector<at::Tensor> edz_eydz_cuda_h(at::Tensor z, at::Tensor dz, at::Tensor weight, at::Tensor bias,
                                      bool affine, float eps) {
  CHECK_INPUT(z);
  CHECK_INPUT(dz);
  CHECK_INPUT(weight);
  CHECK_INPUT(bias);

  // Extract dimensions
  int64_t num, chn, sp;
  get_dims(z, num, chn, sp);

  auto edz = at::empty(z.type().toScalarType(at::kFloat), {chn});
  auto eydz = at::empty(z.type().toScalarType(at::kFloat), {chn});

  // Run kernel
  dim3 blocks(chn);
  dim3 threads(getNumThreads(sp));
  edz_eydz_kernel_h<<<blocks, threads>>>(
        reinterpret_cast<half*>(z.data<at::Half>()),
        reinterpret_cast<half*>(dz.data<at::Half>()),
        weight.data<float>(),
        bias.data<float>(),
        edz.data<float>(),
        eydz.data<float>(),
        affine, eps, num, chn, sp);
 
  return {edz, eydz};
}

__global__ void backward_kernel_h(const half *z, const half *dz, const float *var, const float *weight, const float *bias, const float *edz,
                                const float *eydz, half *dx, float *dweight, float *dbias,
                                bool affine, float eps, int num, int chn, int sp) {
  int plane = blockIdx.x;

  float _weight = affine ? abs(weight[plane]) + eps : 1.f;
  float _bias = affine ? bias[plane] : 0.f;
  float _var = var[plane];
  float _edz = edz[plane];
  float _eydz = eydz[plane];

  float _mul = _weight * rsqrt(_var + eps);
  float count = float(num * sp);

  for (int batch = 0; batch < num; ++batch) {
    for (int n = threadIdx.x; n < sp; n += blockDim.x) {
      float _dz = __half2float(dz[(batch * chn + plane) * sp + n]);
      float _y = (__half2float(z[(batch * chn + plane) * sp + n]) - _bias) / _weight;

      dx[(batch * chn + plane) * sp + n] = __float2half((_dz - _edz / count - _y * _eydz / count) * _mul);
    }
  }

  if (threadIdx.x == 0) {
    if (affine) {
      dweight[plane] = weight[plane] > 0 ? _eydz : -_eydz;
      dbias[plane] = _edz;
    }
  }
}

std::vector<at::Tensor> backward_cuda_h(at::Tensor z, at::Tensor dz, at::Tensor var, at::Tensor weight, at::Tensor bias,
                                      at::Tensor edz, at::Tensor eydz, bool affine, float eps) {
  CHECK_INPUT(z);
  CHECK_INPUT(dz);
  CHECK_INPUT(var);
  CHECK_INPUT(weight);
  CHECK_INPUT(bias);
  CHECK_INPUT(edz);
  CHECK_INPUT(eydz);

  // Extract dimensions
  int64_t num, chn, sp;
  get_dims(z, num, chn, sp);

  auto dx = at::zeros_like(z);
  auto dweight = at::zeros_like(weight);
  auto dbias = at::zeros_like(bias);

  // Run kernel
  dim3 blocks(chn);
  dim3 threads(getNumThreads(sp));
  backward_kernel_h<<<blocks, threads>>>(
        reinterpret_cast<half*>(z.data<at::Half>()),
        reinterpret_cast<half*>(dz.data<at::Half>()),
        var.data<float>(),
        weight.data<float>(),
        bias.data<float>(),
        edz.data<float>(),
        eydz.data<float>(),
        reinterpret_cast<half*>(dx.data<at::Half>()),
        dweight.data<float>(),
        dbias.data<float>(),
        affine, eps, num, chn, sp);

  return {dx, dweight, dbias};
}

__global__ void leaky_relu_backward_impl_h(half *z, half *dz, float slope, int64_t count) {
   for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < count;  i += blockDim.x * gridDim.x){
       float _z = __half2float(z[i]);
       if(_z<0){
	       dz[i]=__float2half(__half2float(dz[i])*slope);
	       z[i]=__float2half(_z/slope);
       }
   }
}

void leaky_relu_backward_cuda_h(at::Tensor z, at::Tensor dz, float slope) {
  CHECK_INPUT(z);
  CHECK_INPUT(dz);

  int64_t count = z.numel();
  dim3 threads(512);
  dim3 blocks = (count + threads.x - 1) / threads.x;

  leaky_relu_backward_impl_h<<<blocks,threads>>>(
        reinterpret_cast<half*>(z.data<at::Half>()),
        reinterpret_cast<half*>(dz.data<at::Half>()),
        slope, count
  );
}

