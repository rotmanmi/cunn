#include "TH.h"
#include "THCDeviceTensor.cuh"
#include "THCDeviceTensorUtils.cuh"
#include "THCDeviceUtils.cuh"

#include "utils.h"

__global__ void cuda_VolumetricAveragePooling_updateOutput(
  THCDeviceTensor<float, 4> input, THCDeviceTensor<float, 4> output,
  int kT, int kH, int kW, int dT, int dH, int dW, float normFactor) {
  int oCol   = blockIdx.x * blockDim.x + threadIdx.x;
  int oRow   = blockIdx.y * blockDim.y + threadIdx.y;
  int oFrame = blockIdx.z % output.getSize(1); // output frame/time
  int slice  = blockIdx.z / output.getSize(1); // output slice/feature

  if (oRow < output.getSize(2) && oCol < output.getSize(3)) {
    float sum = 0.0;
    const int frameStride = input.getSize(2) * input.getSize(3);
    float *in = &input[slice][oFrame * dT][oRow * dH][oCol * dW];
    int frameOffset = 0;
    for (int frame = 0; frame < kT; ++frame) {
      int rowOffset = frameOffset;
      for (int row = 0; row < kH; ++row) {
        int offset = rowOffset;
        for (int col = 0; col < kW; ++col) {
#if __CUDA_ARCH__ >= 350
          sum += __ldg(in + offset);
#else
          sum += *(in + offset);
#endif
          ++offset;
        }
        rowOffset += input.getSize(3);
      }
      frameOffset += frameStride;
    }
    output[slice][oFrame][oRow][oCol] = sum * normFactor;
  }
}

// Inner-most loop size (kW) passed as template parameter for
// performance reasons.
//
template<int KERNEL_WIDTH>
__global__ void cuda_VolumetricAveragePooling_updateOutput(
  THCDeviceTensor<float, 4> input, THCDeviceTensor<float, 4> output,
  int kT, int kH, int dT, int dH, int dW, float normFactor) {
  int oCol   = blockIdx.x * blockDim.x + threadIdx.x;
  int oRow   = blockIdx.y * blockDim.y + threadIdx.y;
  int oFrame = blockIdx.z % output.getSize(1); // output frame/time
  int slice  = blockIdx.z / output.getSize(1); // output slice/feature

  if (oRow < output.getSize(2) && oCol < output.getSize(3)) {
    float sum = 0.0;
    const int frameStride = input.getSize(2) * input.getSize(3);
    float *in = &input[slice][oFrame * dT][oRow * dH][oCol * dW];
    int frameOffset = 0;
    for (int frame = 0; frame < kT; ++frame) {
      int rowOffset = frameOffset;
      for (int row = 0; row < kH; ++row) {
        int offset = rowOffset;
        for (int col = 0; col < KERNEL_WIDTH; ++col) {
#if __CUDA_ARCH__ >= 350
          sum += __ldg(in + offset);
#else
          sum += *(in + offset);
#endif
          ++offset;
        }
        rowOffset += input.getSize(3);
      }
      frameOffset += frameStride;
    }
    output[slice][oFrame][oRow][oCol] = sum * normFactor;
  }
}

#define LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(KW) case KW: \
  cuda_VolumetricAveragePooling_updateOutput<KW><<<grid, block>>>(       \
    cudaInput, cudaOutput, kT, kH, dT, dH, dW, normFactor);             \
  break


static int cunn_VolumetricAveragePooling_updateOutput(lua_State *L) {
  // State
  THCState *state = getCutorchState(L);
  // Input
  THCudaTensor* input = static_cast<THCudaTensor*>(
    luaT_checkudata(L, 2, "torch.CudaTensor"));

  // Params:
  int dT = luaT_getfieldcheckint(L, 1, "dT");
  int dH = luaT_getfieldcheckint(L, 1, "dH");
  int dW = luaT_getfieldcheckint(L, 1, "dW");
  int kT = luaT_getfieldcheckint(L, 1, "kT");
  int kH = luaT_getfieldcheckint(L, 1, "kH");
  int kW = luaT_getfieldcheckint(L, 1, "kW");

  THCudaTensor *output = static_cast<THCudaTensor*>(
    luaT_getfieldcheckudata(L, 1, "output", "torch.CudaTensor"));

  int batchSize;
  int inputSlices;
  int inputTime;
  int inputHeight;
  int inputWidth;

  if (THCudaTensor_nDimension(state, input) == 4) {
    luaL_argcheck(L,
                  THCudaTensor_size(state, input, 1) >= kT &&
                  THCudaTensor_size(state, input, 2) >= kH &&
                  THCudaTensor_size(state, input, 3) >= kW, 2,
                  "input image smaller than kernel size");
    /* sizes */
    batchSize   = 1;
    inputSlices = THCudaTensor_size(state, input, 0);
    inputTime   = THCudaTensor_size(state, input, 1);
    inputHeight = THCudaTensor_size(state, input, 2);
    inputWidth  = THCudaTensor_size(state, input, 3);
  } else if (THCudaTensor_nDimension(state, input) == 5) {
    luaL_argcheck(L,
                  THCudaTensor_size(state, input, 2) >= kT &&
                  THCudaTensor_size(state, input, 3) >= kH &&
                  THCudaTensor_size(state, input, 4) >= kW, 2,
                  "input image smaller than kernel size");
    /* sizes */
    batchSize   = THCudaTensor_size(state, input, 0);
    inputSlices = THCudaTensor_size(state, input, 1);
    inputTime   = THCudaTensor_size(state, input, 2);
    inputHeight = THCudaTensor_size(state, input, 3);
    inputWidth  = THCudaTensor_size(state, input, 4);
  } else {
    luaL_argcheck(L, 0, 2, "4D or 5D tensor expected");
  }

  int outputTime   = (inputTime   - kT) / dT + 1;
  int outputHeight = (inputHeight - kH) / dH + 1;
  int outputWidth  = (inputWidth  - kW) / dW + 1;

  if (input->nDimension == 4) { /* 4D */
    /* resize output */
    THCudaTensor_resize4d(state, output, inputSlices,
                          outputTime, outputHeight, outputWidth);
  } else { /* 5D */
    THCudaTensor_resize5d(state, output, batchSize, inputSlices,
                          outputTime, outputHeight, outputWidth);
  }

  input = THCudaTensor_newContiguous(state, input);

  // Collapse batch and feature dimensions
  THCDeviceTensor<float, 4> cudaInput;
  THCDeviceTensor<float, 4> cudaOutput;
  if (THCudaTensor_nDimension(state, input) == 4) {
    cudaInput  = toDeviceTensor<float, 4>(state, input);
    cudaOutput = toDeviceTensor<float, 4>(state, output);
  } else {
    cudaInput = toDeviceTensor<float, 5>(state, input).downcastOuter<4>();
    cudaOutput =
      toDeviceTensor<float, 5>(state, output).downcastOuter<4>();
  }

  dim3 block(32, 8);
  dim3 grid(THCCeilDiv(outputWidth, static_cast<int>(block.x)),
            THCCeilDiv(outputHeight, static_cast<int>(block.y)),
            outputTime * inputSlices * batchSize);
  float normFactor = 1.0f / static_cast<float>(kT * kH * kW);
  switch (kW) {
    LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(1);
    LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(2);
    LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(3);
    LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(4);
    LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(5);
    LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(6);
    LAUNCH_UPDATE_OUTPUT_KERNEL_WIDTH(7);
    default:
      cuda_VolumetricAveragePooling_updateOutput<<<grid, block>>>(cudaInput,
                                                                  cudaOutput,
                                                                  kT, kH, kW,
                                                                  dT, dH, dW,
                                                                  normFactor);
      break;
  }

  THCudaTensor_free(state, input);

  return 1;
}

__global__ void cuda_VolumetricAveragePooling_updateGradInput_Stride1(
  THCDeviceTensor<float, 4> gradOutput,
  THCDeviceTensor<float, 4> gradInput,
  int kT, int kH, int kW, float normFactor) {
  int iCol   = blockIdx.x * blockDim.x + threadIdx.x;
  int iRow   = blockIdx.y * blockDim.y + threadIdx.y;
  int iFrame = blockIdx.z % gradInput.getSize(1); // input frame/time
  int slice  = blockIdx.z / gradInput.getSize(1); // input slice/feature

  // guard against over-tiled threads
  if (iRow < gradInput.getSize(2) && iCol < gradInput.getSize(3)) {
    float sum = 0.0;
    float *gOut = &gradOutput[slice][max(0, iFrame - kT + 1)]
      [max(0, iRow - kH + 1)][max(0, iCol - kW + 1)];
    int frameOffset = 0;
    for (int oFrame  = max(0, iFrame - kT + 1);
         oFrame < min(iFrame + 1, gradOutput.getSize(1));
         ++oFrame) {
      int rowOffset = frameOffset;
      for (int oRow = max(0, iRow - kH + 1);
           oRow < min(iRow + 1, gradOutput.getSize(2));
           ++oRow) {
        int colOffset = rowOffset;
        for (int oCol = max(0, iCol - kW + 1);
             oCol < min(iCol + 1, gradOutput.getSize(3));
             ++oCol) {
          sum += gOut[colOffset];
          ++colOffset;
        }
        rowOffset += gradOutput.getSize(3);
      }
      frameOffset += gradOutput.getSize(2) * gradOutput.getSize(3);
    }
    gradInput[slice][iFrame][iRow][iCol] = sum * normFactor;
  }
}

__global__ void cuda_VolumetricAveragePooling_updateGradInput_atomicAdd(
  THCDeviceTensor<float, 4> gradOutput,
  THCDeviceTensor<float, 4> gradInput,
  int kT, int kH, int kW, int dT, int dH, int dW) {
  int oCol   = blockIdx.x * blockDim.x + threadIdx.x;
  int oRow   = blockIdx.y * blockDim.y + threadIdx.y;
  int oFrame = blockIdx.z % gradOutput.getSize(1); // gradOutput frame/time
  int slice  = blockIdx.z / gradOutput.getSize(1); // gradOutput slice/feature

  // guard against over-tiled threads
  if (oRow < gradOutput.getSize(2) && oCol < gradOutput.getSize(3)) {
    float val = gradOutput[slice][oFrame][oRow][oCol] / (kT * kH * kW);
    for (int iFrame = oFrame * dT; iFrame < oFrame * dT + kT; ++iFrame) {
      for (int iRow = oRow * dH; iRow < oRow * dH + kH; ++iRow) {
        for (int iCol = oCol * dW; iCol < oCol * dW + kW; ++iCol) {
          atomicAdd(&gradInput[slice][iFrame][iRow][iCol], val);
        }
      }
    }
  }
}

__global__ void cuda_VolumetricAveragePooling_updateGradInput(
  THCDeviceTensor<float, 4> gradOutput,
  THCDeviceTensor<float, 4> gradInput,
  int kT, int kH, int kW, int dT, int dH, int dW) {
  int oCol   = blockIdx.x * blockDim.x + threadIdx.x;
  int oRow   = blockIdx.y * blockDim.y + threadIdx.y;
  int oFrame = blockIdx.z % gradOutput.getSize(1); // gradOutput frame/time
  int slice  = blockIdx.z / gradOutput.getSize(1); // gradOutput slice/feature

  // guard against over-tiled threads
  if (oRow < gradOutput.getSize(2) && oCol < gradOutput.getSize(3)) {
    float val = gradOutput[slice][oFrame][oRow][oCol] / (kT * kH * kW);
    for (int iFrame = oFrame * dT; iFrame < oFrame * dT + kT; ++iFrame) {
      for (int iRow = oRow * dH; iRow < oRow * dH + kH; ++iRow) {
        for (int iCol = oCol * dW; iCol < oCol * dW + kW; ++iCol) {
          gradInput[slice][iFrame][iRow][iCol] = val;
        }
      }
    }
  }
}


static int cunn_VolumetricAveragePooling_updateGradInput(lua_State *L) {
  // State
  THCState *state = getCutorchState(L);
  // Input
  THCudaTensor* input = static_cast<THCudaTensor*>(
    luaT_checkudata(L, 2, "torch.CudaTensor"));
  // gradOutput
  THCudaTensor* gradOutput = static_cast<THCudaTensor*>(
    luaT_checkudata(L, 3, "torch.CudaTensor"));
  // Params
  int dT = luaT_getfieldcheckint(L, 1, "dT");
  int dH = luaT_getfieldcheckint(L, 1, "dH");
  int dW = luaT_getfieldcheckint(L, 1, "dW");
  int kT = luaT_getfieldcheckint(L, 1, "kT");
  int kH = luaT_getfieldcheckint(L, 1, "kH");
  int kW = luaT_getfieldcheckint(L, 1, "kW");

  bool kernelsOverlap = (dT < kT) || (dH < kH) || (dW < kW);

  // gradInput
  THCudaTensor* gradInput = static_cast<THCudaTensor*>(
    luaT_getfieldcheckudata(L, 1, "gradInput", "torch.CudaTensor"));

  // Resize and initialize result tensor.
  THCudaTensor_resizeAs(state, gradInput, input);
  THCudaTensor_zero(state, gradInput);

  int batchSize;
  int inputSlices;
  int inputTime;
  int inputHeight;
  int inputWidth;

  int outputTime;
  int outputHeight;
  int outputWidth;

  if (THCudaTensor_nDimension(state, input) == 4) { /* 4D */
    batchSize = 1;
    inputSlices  = THCudaTensor_size(state, input, 0);
    inputTime    = THCudaTensor_size(state, input, 1);
    inputHeight  = THCudaTensor_size(state, input, 2);
    inputWidth   = THCudaTensor_size(state, input, 3);

    outputTime   = THCudaTensor_size(state, gradOutput, 1);
    outputHeight = THCudaTensor_size(state, gradOutput, 2);
    outputWidth  = THCudaTensor_size(state, gradOutput, 3);
  } else {
    batchSize    = THCudaTensor_size(state, input, 0);
    inputSlices  = THCudaTensor_size(state, input, 1);
    inputTime    = THCudaTensor_size(state, input, 2);
    inputHeight  = THCudaTensor_size(state, input, 3);
    inputWidth   = THCudaTensor_size(state, input, 4);

    outputTime   = THCudaTensor_size(state, gradOutput, 2);
    outputHeight = THCudaTensor_size(state, gradOutput, 3);
    outputWidth  = THCudaTensor_size(state, gradOutput, 4);
  }

  gradOutput = THCudaTensor_newContiguous(state, gradOutput);

  // Collapse batch and feature dimensions
  THCDeviceTensor<float, 4> cudaGradInput;
  THCDeviceTensor<float, 4> cudaGradOutput;
  if (THCudaTensor_nDimension(state, input) == 4) {
    cudaGradInput  = toDeviceTensor<float, 4>(state, gradInput);
    cudaGradOutput = toDeviceTensor<float, 4>(state, gradOutput);
  } else {
    cudaGradInput =
      toDeviceTensor<float, 5>(state, gradInput).downcastOuter<4>();
    cudaGradOutput =
      toDeviceTensor<float, 5>(state, gradOutput).downcastOuter<4>();
  }

  dim3 block(32, 8);

  // Optimizing for stride 1 is probably only of limited value, but this
  // specialization yields 3x speedup over the atomicAdd implementation.
  if (dT == 1 && dH == 1 && dW == 1) {
    dim3 grid(THCCeilDiv(inputWidth, static_cast<int>(block.x)),
              THCCeilDiv(inputHeight, static_cast<int>(block.y)),
              inputTime * inputSlices * batchSize);
    cuda_VolumetricAveragePooling_updateGradInput_Stride1<<<grid, block>>>(
      cudaGradOutput, cudaGradInput, kT, kH, kW, 1.0f/(kT * kH * kW));

  } else {
    dim3 grid(THCCeilDiv(outputWidth, static_cast<int>(block.x)),
              THCCeilDiv(outputHeight, static_cast<int>(block.y)),
              outputTime * inputSlices * batchSize);
    if (kernelsOverlap) {
      cuda_VolumetricAveragePooling_updateGradInput_atomicAdd<<<grid, block>>>(
        cudaGradOutput, cudaGradInput, kT, kH, kW, dT, dH, dW);
    } else {
      cuda_VolumetricAveragePooling_updateGradInput<<<grid, block>>>(
        cudaGradOutput, cudaGradInput, kT, kH, kW, dT, dH, dW);
    }
  }

  THCudaTensor_free(state, gradOutput);

  return 1;
}

static const struct luaL_Reg cunn_VolumetricAveragePooling__ [] = {
  {"VolumetricAveragePooling_updateOutput",
   cunn_VolumetricAveragePooling_updateOutput},
  {"VolumetricAveragePooling_updateGradInput",
   cunn_VolumetricAveragePooling_updateGradInput},
  {NULL, NULL}
};

void cunn_VolumetricAveragePooling_init(lua_State *L)
{
  luaT_pushmetatable(L, "torch.CudaTensor");
  luaT_registeratname(L, cunn_VolumetricAveragePooling__, "nn");
  lua_pop(L,1);
}
