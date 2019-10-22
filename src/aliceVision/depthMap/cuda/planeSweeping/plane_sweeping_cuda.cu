// This file is part of the AliceVision project.
// Copyright (c) 2017 AliceVision contributors.
// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

#include <aliceVision/depthMap/cuda/commonStructures.hpp>
#include <aliceVision/depthMap/cuda/deviceCommon/device_color.cu>
#include <aliceVision/depthMap/cuda/deviceCommon/device_patch_es.cu>
#include <aliceVision/depthMap/cuda/deviceCommon/device_eig33.cu>
#include <aliceVision/depthMap/cuda/planeSweeping/device_code.cu>
#include <aliceVision/depthMap/cuda/planeSweeping/device_code_refine.cu>
#include <aliceVision/depthMap/cuda/planeSweeping/device_code_volume.cu>
#include <aliceVision/depthMap/cuda/planeSweeping/device_code_fuse.cu>
#include <aliceVision/depthMap/cuda/planeSweeping/plane_sweeping_cuda.hpp>
#include <aliceVision/depthMap/cuda/planeSweeping/host_utils.h>
#include <aliceVision/depthMap/cuda/images/gauss_filter.hpp>

#include <math_constants.h>

#include <iostream>
#include <algorithm>
#include <map>
#include <array>

namespace aliceVision {
namespace depthMap {

// Macro for checking cuda errors
#define CHECK_CUDA_ERROR()                                                    \
    if(cudaError_t err = cudaGetLastError())                                  \
    {                                                                         \
        fprintf(stderr, "\n\nCUDAError: %s\n", cudaGetErrorString(err));      \
        fprintf(stderr, "  file:       %s\n", __FILE__);                      \
        fprintf(stderr, "  function:   %s\n", __FUNCTION__);                  \
        fprintf(stderr, "  line:       %d\n\n", __LINE__);                    \
        std::stringstream s;                                                  \
        s << "\n  CUDA Error: " << cudaGetErrorString(err)                    \
          << "\n  file:       " << __FILE__                                   \
          << "\n  function:   " << __FUNCTION__                               \
          << "\n  line:       " << __LINE__ << "\n";                          \
        throw std::runtime_error(s.str());                                    \
    }

#define ALICEVISION_CU_PRINT_DEBUG(a) \
    std::cerr << a << std::endl;

#define ALICEVISION_CU_PRINT_ERROR(a) \
    std::cerr << a << std::endl;

/* CUDA can help us to find good block sizes for a kernel, depending
 * on architecture. Call configure_* functions and use *_block
 * afterwards.
 */
static bool volume_slice_kernel_block_set = false;
static dim3 volume_slice_kernel_block( 32, 1, 1 ); // minimal default settings

__host__ void configure_volume_slice_kernel( )
{
    if( volume_slice_kernel_block_set ) return;
    volume_slice_kernel_block_set = true;

    int recommendedMinGridSize;
    int recommendedBlockSize;
    cudaError_t err;
    err = cudaOccupancyMaxPotentialBlockSize( &recommendedMinGridSize,
                                              &recommendedBlockSize,
                                              volume_slice_kernel,
                                              0, // dynamic shared mem size: none used
                                              0 ); // no block size limit, 1 thread OK
    if( err != cudaSuccess )
    {
        ALICEVISION_CU_PRINT_DEBUG( "cudaOccupancyMaxPotentialBlockSize failed for kernel volume_slice_kernel, using defaults" );
    }
    else
    {
        if( recommendedBlockSize > 32 )
        {
            volume_slice_kernel_block.x = 32;
            volume_slice_kernel_block.y = divUp( recommendedBlockSize, 32 );
        }
    }
}

__host__ float3 ps_M3x3mulV3(const float* M3x3, const float3& V)
{
    return make_float3(M3x3[0] * V.x + M3x3[3] * V.y + M3x3[6] * V.z, M3x3[1] * V.x + M3x3[4] * V.y + M3x3[7] * V.z,
                       M3x3[2] * V.x + M3x3[5] * V.y + M3x3[8] * V.z);
}

__host__ void ps_normalize(float3& a)
{
    float d = sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
    a.x /= d;
    a.y /= d;
    a.z /= d;
}

void pr_printfDeviceMemoryInfo()
{
    size_t iavail;
    size_t itotal;
    cudaMemGetInfo(&iavail, &itotal);
    size_t iused = itotal - iavail;

    double avail = double(iavail) / (1024.0 * 1024.0);
    double total = double(itotal) / (1024.0 * 1024.0);
    double used = double(iused) / (1024.0 * 1024.0);

    int CUDAdeviceNo;
    cudaGetDevice(&CUDAdeviceNo);

    printf("Device %i memory - used: %f, free: %f, total: %f\n", CUDAdeviceNo, used, avail, total);
}

__host__ void ps_initCameraMatrix( CameraStructBase& base )
{
    float3 z;
    z.x = 0.0f;
    z.y = 0.0f;
    z.z = 1.0f;
    base.ZVect = ps_M3x3mulV3(base.iR, z);
    ps_normalize(base.ZVect);

    float3 y;
    y.x = 0.0f;
    y.y = 1.0f;
    y.z = 0.0f;
    base.YVect = ps_M3x3mulV3(base.iR, y);
    ps_normalize(base.YVect);

    float3 x;
    x.x = 1.0f;
    x.y = 0.0f;
    x.z = 0.0f;
    base.XVect = ps_M3x3mulV3(base.iR, x);
    ps_normalize(base.XVect);
}

int ps_listCUDADevices(bool verbose)
{
    int num_gpus = 0; // number of CUDA GPUs

    // determine the number of CUDA capable GPUs
    cudaError_t err = cudaGetDeviceCount(&num_gpus);
    CHECK_CUDA_ERROR();
    if(err != cudaSuccess)
    {
        printf("Error getting cuda device count");
        return 0;
    }

    if(num_gpus < 1)
    {
        printf("ERROR: no CUDA capable devices detected");
        return 0;
    }

    if(verbose == true)
    {
        // display CPU and GPU configuration
        printf("number of CUDA devices:\t%d\n", num_gpus);
        for(int i = 0; i < num_gpus; i++)
        {
            cudaDeviceProp dprop;
            cudaGetDeviceProperties(&dprop, i);
            printf("   %d: %s\n", i, dprop.name);
        }
    }

    return num_gpus;
}

static int ps_sub_deviceAllocate(Pyramid& pyramid, int width, int height, int scales )
{
    int bytesAllocated = 0;

    pyramid.resize(scales);

    for(int s = 0; s < scales; s++)
    {
        int w = width / (s + 1);
        int h = height / (s + 1);
        // printf("ps_deviceAllocate: CudaDeviceMemoryPitched: [c%i][s%i] %ix%i\n", c, s, w, h);
        pyramid[s].arr = new CudaDeviceMemoryPitched<CudaRGBA, 2>(CudaSize<2>(w, h));
        bytesAllocated += pyramid[s].arr->getBytesPadded();

        cudaTextureDesc  tex_desc;
        memset(&tex_desc, 0, sizeof(cudaTextureDesc));
        tex_desc.normalizedCoords = 0; // addressed (x,y) in [width,height]
        tex_desc.addressMode[0]   = cudaAddressModeClamp;
        tex_desc.addressMode[1]   = cudaAddressModeClamp;
        tex_desc.addressMode[2]   = cudaAddressModeClamp;
// #ifdef ALICEVISION_DEPTHMAP_TEXTURE_USE_UCHAR
//      tex_desc.readMode = cudaReadModeNormalizedFloat; // uchar to float [0:1], see tex2d_float4 function
// #else
        tex_desc.readMode = cudaReadModeElementType;
// #endif
#ifdef ALICEVISION_DEPTHMAP_TEXTURE_USE_INTERPOLATION
        // with subpixel interpolation (can have a large performance impact on some graphic cards)
        tex_desc.filterMode = cudaFilterModeLinear;
#else
        // without interpolation
        tex_desc.filterMode = cudaFilterModePoint;
#endif

        cudaResourceDesc res_desc;
        res_desc.resType = cudaResourceTypePitch2D;
        res_desc.res.pitch2D.desc = cudaCreateChannelDesc<CudaRGBA>();
        res_desc.res.pitch2D.devPtr       = pyramid[s].arr->getBuffer();
        res_desc.res.pitch2D.width        = pyramid[s].arr->getSize()[0];
        res_desc.res.pitch2D.height       = pyramid[s].arr->getSize()[1];
        res_desc.res.pitch2D.pitchInBytes = pyramid[s].arr->getPitch();

        cudaError_t err = cudaCreateTextureObject( &pyramid[s].tex, &res_desc, &tex_desc, 0 );
        THROW_ON_CUDA_ERROR( err, "Failed to bind texture object to cam array" );
    }

    return bytesAllocated;
}

void ps_deviceAllocate(Pyramids& ps_texs_arr, int ncams, int width, int height, int scales,
                       int deviceId)
{

    cudaError_t outval = cudaSetDevice(deviceId);
    if( outval != cudaSuccess )
    {
        ALICEVISION_CU_PRINT_ERROR( "Failed to set CUDA device " << deviceId << " for thread: " << cudaGetErrorString(outval) );
    }
    printf("Setting CUDA device to %i\n", deviceId);

    pr_printfDeviceMemoryInfo();

    // copy textures to the device
    int allBytes = 0;
    ps_texs_arr.resize(ncams);
    for(int c = 0; c < ncams; c++)
    {
        allBytes += ps_sub_deviceAllocate( ps_texs_arr[c], width, height, scales );
    }

    CHECK_CUDA_ERROR();

    // calcDCTCoefficients();
    // CHECK_CUDA_ERROR();

    printf("scales %i\n",scales);

    printf("total size of preallocated images in GPU memory: %f\n",double(allBytes)/(1024.0*1024.0));

    pr_printfDeviceMemoryInfo();
    // printf("ps_deviceAllocate - done\n");
}

void ps_testCUDAdeviceNo(int CUDAdeviceNo)
{
    int myCUDAdeviceNo;
    cudaGetDevice(&myCUDAdeviceNo);
    if(myCUDAdeviceNo != CUDAdeviceNo)
    {
        printf("WARNING different device %i %i\n", myCUDAdeviceNo, CUDAdeviceNo);
    }
}

void ps_device_updateCam( const CameraStruct& cam, int CUDAdeviceNo,
                          int scales, int w, int h)
{
    ALICEVISION_CU_PRINT_DEBUG(std::endl
              << "Calling " << __FUNCTION__ << std::endl
              << "    for camera id " << cam.camId << " and " << scales << " scales"
              << ", w: " << w << ", h: " << h
              << std::endl);

    Pyramid& pyramid = *cam.pyramid;

    {
        /* copy texture's data from host to device */
        pyramid[0].arr->copyFrom( (*cam.tex_rgba_hmh) );

        const dim3 block(32, 2, 1);
        const dim3 grid(divUp(w, block.x), divUp(h, block.y), 1);
        ALICEVISION_CU_PRINT_DEBUG("rgb2lab_kernel: block=(" << block.x << ", " << block.y << ", " << block.z << "), grid=(" << grid.x << ", " << grid.y << ", " << grid.z << ")");

        /* in-place color conversion into CIELAB */
        rgb2lab_kernel<<<grid, block>>>(
            pyramid[0].arr->getBuffer(), (*cam.pyramid)[0].arr->getPitch(),
            w, h);
        CHECK_CUDA_ERROR();
    }

    /* If not done before, initialize Gaussian filters in GPU constant mem.  */
    ps_create_gaussian_arr( CUDAdeviceNo, scales );
    CHECK_CUDA_ERROR();

    /* For each scale, create a Gaussian-filtered and scaled version of the
     * initial texture */
    for(int scale = 1; scale < scales; ++scale)
    {
        const int radius = scale + 1;
        // const int sWidth = w / (scale + 1);
        // const int sHeight = h / (scale + 1);
        // ALICEVISION_CU_PRINT_DEBUG("Create downscaled image for camera id " << camId << " at scale " << scale << ": " << sWidth << "x" << sHeight);

        // const dim3 block(32, 2, 1);
        // const dim3 grid(divUp(sWidth, block.x), divUp(sHeight, block.y), 1);
        // ALICEVISION_CU_PRINT_DEBUG("ps_downscale_gauss: block=(" << block.x << ", " << block.y << ", " << block.z << "), grid=(" << grid.x << ", " << grid.y << ", " << grid.z << ")");

        ps_downscale_gauss(pyramid, scale, w, h, radius);
        CHECK_CUDA_ERROR();
    }

    CHECK_CUDA_ERROR();
}

void ps_deviceDeallocate(Pyramids& ps_texs_arr, int CUDAdeviceNo, int ncams, int scales)
{
    for(int c = 0; c < ncams; c++)
    {
        for(int s = 0; s < scales; s++)
        {
            delete ps_texs_arr[c][s].arr;
            cudaDestroyTextureObject( ps_texs_arr[c][s].tex );
        }
    }
}


/**
 * @param[inout] d_volSimT similarity volume
 */
void ps_aggregatePathVolume(
    CudaDeviceMemoryPitched<TSim, 3>& d_volAgr,
    const CudaDeviceMemoryPitched<TSim, 3>& d_volSim,
    const CudaSize<3>& volDim,
    const CudaSize<3>& axisT,
    cudaTextureObject_t rc_tex,
    float P1, float P2,
    bool invY, int filteringIndex,
    bool verbose)
{
    if(verbose)
        printf("ps_aggregatePathVolume\n");

    size_t volDimX = volDim[axisT[0]];
    size_t volDimY = volDim[axisT[1]];
    size_t volDimZ = volDim[axisT[2]];

    int3 volDim_ = make_int3(volDim[0], volDim[1], volDim[2]);
    int3 axisT_ = make_int3(axisT[0], axisT[1], axisT[2]);
    int ySign = (invY ? -1 : 1);

    ///////////////////////////////////////////////////////////////////////////////
    // setup block and grid
    const int blockSize = 8;
    const dim3 blockVolXZ(blockSize, blockSize, 1);
    const dim3 gridVolXZ(divUp(volDimX, blockVolXZ.x), divUp(volDimZ, blockVolXZ.y), 1);

    const int blockSizeL = 64;
    const dim3 blockColZ(blockSizeL, 1, 1);
    const dim3 gridColZ(divUp(volDimZ, blockColZ.x), 1, 1);

    const dim3 blockVolSlide(blockSizeL, 1, 1);
    const dim3 gridVolSlide(divUp(volDimX, blockVolSlide.x), volDimZ, 1);

    CudaDeviceMemoryPitched<TSim, 2> d_sliceBufferA(CudaSize<2>(volDimX, volDimZ));
    CudaDeviceMemoryPitched<TSim, 2> d_sliceBufferB(CudaSize<2>(volDimX, volDimZ));

    CudaDeviceMemoryPitched<TSim, 2>* d_xzSliceForY = &d_sliceBufferA; // Y slice
    CudaDeviceMemoryPitched<TSim, 2>* d_xzSliceForYm1 = &d_sliceBufferB; // Y-1 slice

    CudaDeviceMemoryPitched<TSim, 2> d_bestSimInYm1(CudaSize<2>(volDimZ, 1)); // best sim score along the Y axis for each Z value

    // Copy the first XZ plane (at Y=0) from 'd_volSim' into 'd_xzSliceForYm1'
    volume_getVolumeXZSlice_kernel<TSim, TSim><<<gridVolXZ, blockVolXZ>>>(
        d_xzSliceForYm1->getBuffer(),
        d_xzSliceForYm1->getPitch(),
        d_volSim.getBuffer(),
        d_volSim.getBytesPaddedUpToDim(1),
        d_volSim.getBytesPaddedUpToDim(0),
        volDim_, axisT_, 0); // Y=0

    // Set the first Z plane from 'd_volAgr' to 255
    volume_initVolumeYSlice_kernel<TSim><<<gridVolXZ, blockVolXZ>>>(
        d_volAgr.getBuffer(),
        d_volAgr.getBytesPaddedUpToDim(1),
        d_volAgr.getBytesPaddedUpToDim(0),
        volDim_, axisT_, 0, 255);

    for(int iy = 1; iy < volDimY; ++iy)
    {
        int y = invY ? volDimY - 1 - iy : iy;

        // For each column: compute the best score
        // Foreach x:
        //   d_zBestSimInYm1[x] = min(d_xzSliceForY[1:height])
        volume_computeBestZInSlice_kernel<<<gridColZ, blockColZ>>>(
            d_xzSliceForYm1->getBuffer(), d_xzSliceForYm1->getPitch(),
            d_bestSimInYm1.getBuffer(),
            volDimX, volDimZ);

        // Copy the 'z' plane from 'd_volSimT' into 'd_xzSliceForY'
        volume_getVolumeXZSlice_kernel<TSim, TSim><<<gridVolXZ, blockVolXZ>>>(
            d_xzSliceForY->getBuffer(),
            d_xzSliceForY->getPitch(),
            d_volSim.getBuffer(),
            d_volSim.getBytesPaddedUpToDim(1),
            d_volSim.getBytesPaddedUpToDim(0),
            volDim_, axisT_, y);

        volume_agregateCostVolumeAtXinSlices_kernel<<<gridVolSlide, blockVolSlide>>>(
            rc_tex,
            d_xzSliceForY->getBuffer(), d_xzSliceForY->getPitch(),              // inout: xzSliceForY
            d_xzSliceForYm1->getBuffer(), d_xzSliceForYm1->getPitch(),          // in:    xzSliceForYm1
            d_bestSimInYm1.getBuffer(),                                         // in:    bestSimInYm1
            d_volAgr.getBuffer(), d_volAgr.getBytesPaddedUpToDim(1), d_volAgr.getBytesPaddedUpToDim(0), // out:   volAgr
            volDim_, axisT_,
            y, P1, P2,
            ySign, filteringIndex);

        std::swap(d_xzSliceForYm1, d_xzSliceForY);
    }

    // CHECK_CUDA_ERROR();

    if(verbose)
        printf("ps_aggregatePathVolume done\n");
}

/**
* @param[in] ps_texs_arr table of image (in Lab colorspace) for all scales
* @param[in] rccam RC camera
* @param[inout] iovol_hmh input similarity volume (after Z reduction)
*/
void ps_SGMoptimizeSimVolume(const CameraStruct& rccam,
                             const CudaDeviceMemoryPitched<TSim, 3>& volSim_dmp,
                             CudaDeviceMemoryPitched<TSim, 3>& volSimFiltered_dmp,
                             int volDimX, int volDimY, int volDimZ,
                             const std::string& filteringAxes,
                             bool verbose, float P1, float P2,
                             int scale, int CUDAdeviceNo, int ncamsAllocated)
{
    clock_t tall = tic();

    // setup block and grid
    int block_size = 8;
    dim3 blockvol(block_size, block_size, 1);
    dim3 gridvol(divUp(volDimX, block_size), divUp(volDimY, block_size), 1);

    if (verbose)
        printf("ps_SGMoptimizeSimVolume: Total size of volume map in GPU memory: %f\n", double(volSim_dmp.getBytesPadded())/(1024.0*1024.0));

    // update aggregation volume
    int npaths = 0;
    Pyramid& rc_pyramid = *rccam.pyramid;
    cudaTextureObject_t rc_tex = rc_pyramid[scale - 1].tex;

    CudaSize<3> volDim(volDimX, volDimY, volDimZ);

    const auto updateAggrVolume = [&](const std::array<int, 3>& axisTrn, bool invX)
                                  {
                                      CudaSize<3> axisT(axisTrn[0], axisTrn[1], axisTrn[2]);

                                      ps_aggregatePathVolume(volSimFiltered_dmp,
                                                          volSim_dmp,
                                                          volDim,
                                                          axisT,
                                                          rc_tex,
                                                          P1, P2,
                                                          invX,
                                                          npaths,
                                                          verbose);
                                      npaths++;
                                  };

    // Filtering is done on the last axis
    const std::map<char, std::array<int, 3>> mapAxes = {
        {'X', {1, 0, 2}}, // XYZ -> YXZ
        {'Y', {0, 1, 2}}, // XYZ
        {'Z', {0, 1, 2}}, // XYZ
    };

    for (char axis : filteringAxes)
    {
        const std::array<int, 3>& axisT = mapAxes.at(axis);
        updateAggrVolume(axisT, false); // without transpose
        updateAggrVolume(axisT, true); // with transpose of the last axis
    }

    if (verbose)
    {
        printf("SGM volume gpu elapsed time: %f ms \n", toc(tall));
        printf("ps_SGMoptimizeSimVolume done\n");
    }
}

void ps_SGMretrieveBestDepth(
    CudaDeviceMemoryPitched<float, 2>& bestDepth_dmp, CudaDeviceMemoryPitched<float, 2>& bestSim_dmp,
    const CameraStruct& rccam,
    const CudaDeviceMemory<float>& depths_d,
    CudaDeviceMemoryPitched<TSim, 3>& volSim_dmp,
    int volDimX, int volDimY, int volDimZ, int scaleStep, bool interpolate)
{
  int block_size = 8;
  dim3 block(block_size, block_size, 1);
  dim3 grid(divUp(volDimX, block_size), divUp(volDimY, block_size), 1);

  volume_retrieveBestZ_kernel<<<grid, block>>>(
    *rccam.param_dev,
    bestDepth_dmp.getBuffer(),
    bestDepth_dmp.getBytesPaddedUpToDim(0),
    bestSim_dmp.getBuffer(),
    bestSim_dmp.getBytesPaddedUpToDim(0),
    depths_d.getBuffer(),
    volSim_dmp.getBuffer(),
    volSim_dmp.getBytesPaddedUpToDim(1),
    volSim_dmp.getBytesPaddedUpToDim(0),
    volDimX, volDimY, volDimZ,
    scaleStep,
    interpolate);
}


void ps_initSimilarityVolume(
    CudaDeviceMemoryPitched<TSim, 3>& volBestSim_dmp,
    CudaDeviceMemoryPitched<TSim, 3>& volSecBestSim_dmp,
    int volDimX, int volDimY, int volDimZ)
{
  dim3 block(32, 4, 1);

  dim3 grid(divUp(volDimX, block.x),
    divUp(volDimY, block.y),
    volDimZ);

  volume_init_kernel
    <<<grid, block >>>
    (volBestSim_dmp.getBuffer(),
      volBestSim_dmp.getBytesPaddedUpToDim(1),
      volBestSim_dmp.getBytesPaddedUpToDim(0),
      volDimX, volDimY);
  volume_init_kernel
    <<<grid, block >>>
    (volSecBestSim_dmp.getBuffer(),
      volSecBestSim_dmp.getBytesPaddedUpToDim(1),
      volSecBestSim_dmp.getBytesPaddedUpToDim(0),
      volDimX, volDimY);
}

void ps_initColorVolumeFromCamera(
    CudaDeviceMemoryPitched<float4, 3>& volColor_dmp,
    const CameraStruct& rcam,
    const CameraStruct& tcam,
    cudaTextureObject_t tcam_tex,
    const int tcWidth, const int tcHeight,
    const int depthToStart,
    const CudaDeviceMemory<float>& depths_d,
    int volDimX, int volDimY, int usedVolDimZ, int volStepXY)
{
    dim3 block(32, 4, 1);

    dim3 grid(divUp(volDimX, block.x),
        divUp(volDimY, block.y),
        usedVolDimZ);

    ALICEVISION_CU_PRINT_DEBUG("ps_initColorVolumeFromCamera:" << std::endl
        << "\t- tcam.camId: " << tcam.camId << std::endl
        << "\t- block: " << block.x << ", " << block.y << ", " << block.z << std::endl
        << "\t- grid: " << grid.x << ", " << grid.y << ", " << grid.z << std::endl
        << "\t- volDimX: " << volDimX << ", volDimY: " << volDimY << ", volStepXY: " << volStepXY << std::endl
        << "\t- usedVolDimZ: " << usedVolDimZ << std::endl
        << "\t- depthToStart: " << depthToStart << std::endl
        << "\t- depths_d.getUnitsInDim(0): " << depths_d.getUnitsInDim(0) << std::endl
        << "\t- volColor_dmp.getSize(): " << volColor_dmp.getSize()[0] << ", " << volColor_dmp.getSize()[1] << ", " << volColor_dmp.getSize()[2] << std::endl
        << "\t- volColor_dmp.getBytesPaddedUpToDim(1): " << volColor_dmp.getBytesPaddedUpToDim(1) << std::endl
        << "\t- volColor_dmp.getBytesPaddedUpToDim(0): " << volColor_dmp.getBytesPaddedUpToDim(0) << std::endl
        );

    // cudaDeviceSynchronize();
    // CHECK_CUDA_ERROR();

    volume_initCameraColor_kernel
        <<<grid, block>>>
        (volColor_dmp.getBuffer(),
         volColor_dmp.getBytesPaddedUpToDim(1),
         volColor_dmp.getBytesPaddedUpToDim(0),
         *rcam.param_dev,
         *tcam.param_dev,
         tcam_tex,
         tcWidth, tcHeight,
         depthToStart,
         depths_d.getBuffer(),
         volDimX, volDimY, usedVolDimZ, volStepXY);

    // cudaDeviceSynchronize();
    // CHECK_CUDA_ERROR();
}


void ps_computeSimilarityVolume_precomputedColors(
    cudaTextureObject_t rc_tex,
#ifdef PLANE_SWEEPING_PRECOMPUTED_COLORS_TEXTURE
    cudaTextureObject_t volTcamColors_tex3D,
#else
    const CudaDeviceMemoryPitched<float4, 3>& volTcamColors_dmp,
#endif
    CudaDeviceMemoryPitched<TSim, 3>& volBestSim_dmp,
    CudaDeviceMemoryPitched<TSim, 3>& volSecBestSim_dmp,
    const CameraStruct& rcam, int rcWidth, int rcHeight,
    int volStepXY, int volDimX, int volDimY,
    const OneTC& cell,
    int wsh, int kernelSizeHalf,
    int scale,
    bool verbose,
    float gammaC, float gammaP)
{

    configure_volume_slice_kernel();

    printf("Start depth: %i, nb depths to search: %i \n", cell.getLowestUsedDepth(), cell.getDepthsToSearch());

    dim3 volume_slice_kernel_grid(
        divUp(volDimX, volume_slice_kernel_block.x),
        divUp(volDimY, volume_slice_kernel_block.y),
        cell.getDepthsToSearch());

    ALICEVISION_CU_PRINT_DEBUG("====================");
    ALICEVISION_CU_PRINT_DEBUG("RC: " << rcam.camId);
    ALICEVISION_CU_PRINT_DEBUG("volume_slice_kernel_grid: " << volume_slice_kernel_grid.x << ", " << volume_slice_kernel_grid.y << ", " << volume_slice_kernel_grid.z);
    ALICEVISION_CU_PRINT_DEBUG("volume_slice_kernel_block: " << volume_slice_kernel_block.x << ", " << volume_slice_kernel_block.y << ", " << volume_slice_kernel_block.z);
    ALICEVISION_CU_PRINT_DEBUG("startDepthIndex: " << cell.getDepthToStart());
    ALICEVISION_CU_PRINT_DEBUG("nbDepthsToSearch: " << cell.getDepthsToSearch());
    ALICEVISION_CU_PRINT_DEBUG("startDepthIndex+nbDepthsToSearch: " << cell.getDepthToStart() + cell.getDepthsToSearch());
    ALICEVISION_CU_PRINT_DEBUG("volDimX: " << volDimX << ", volDimY: " << volDimY << ", volStepXY: " << volStepXY);
    ALICEVISION_CU_PRINT_DEBUG("scale: " << scale);
    ALICEVISION_CU_PRINT_DEBUG("rcWidth / scale: " << rcWidth / scale << "x" << rcHeight / scale);
    ALICEVISION_CU_PRINT_DEBUG("====================");

    // cudaDeviceSynchronize();
    // CHECK_CUDA_ERROR();

    volume_estimateSim_twoViews_kernel
        <<<volume_slice_kernel_grid, volume_slice_kernel_block>>>
        (rc_tex,
#ifdef PLANE_SWEEPING_PRECOMPUTED_COLORS_TEXTURE
         volTcamColors_tex3D,
#else
         volTcamColors_dmp.getBuffer(),
         volTcamColors_dmp.getBytesPaddedUpToDim(1),
         volTcamColors_dmp.getBytesPaddedUpToDim(0),
#endif
         cell.getDepthToStart(),
         cell.getDepthsToSearch(),
         rcWidth / scale, rcHeight / scale,
         wsh, gammaC, gammaP,
         volBestSim_dmp.getBuffer(),
         volBestSim_dmp.getBytesPaddedUpToDim(1),
         volBestSim_dmp.getBytesPaddedUpToDim(0),
         volSecBestSim_dmp.getBuffer(),
         volSecBestSim_dmp.getBytesPaddedUpToDim(1),
         volSecBestSim_dmp.getBytesPaddedUpToDim(0),
         scale, volStepXY,
         volDimX, volDimY);

    // cudaDeviceSynchronize();
    // CHECK_CUDA_ERROR();
}


void ps_computeSimilarityVolume(CudaDeviceMemoryPitched<TSim, 3>& volBestSim_dmp,
                                CudaDeviceMemoryPitched<TSim, 3>& volSecBestSim_dmp,
                                const CameraStruct& rcam, int rcWidth, int rcHeight,
                                const CameraStruct& tcam, int tcWidth, int tcHeight,
                                int volStepXY, int volDimX, int volDimY,
                                const CudaDeviceMemory<float>& depths_d,
                                const std::vector<OneTC>& cells,
                                int wsh, int kernelSizeHalf,
                                int scale,
                                bool verbose,
                                float gammaC, float gammaP)
{
    // CHECK_CUDA_ERROR();
    // cudaDeviceSynchronize();

    configure_volume_slice_kernel();

    int s = scale -1;

    const int max_cells = cells.size();

    const int baseDepth = cells[0].getLowestUsedDepth();  // min of all cells
    const int stopDepth = cells[0].getHighestUsedDepth(); // max of all cells

    TSim* gpu_volume_1st = volBestSim_dmp.getBuffer();
    TSim* gpu_volume_2nd = volSecBestSim_dmp.getBuffer();

    if(verbose)
    {
        for(int ci=0; ci<max_cells; ++ci)
        {
            printf("Nb all depths: %i, start depth: %i, nb depths to search: %i \n",
                    (int)depths_d.getUnitsTotal(),
              cells[ci].getLowestUsedDepth(),
              cells[ci].getDepthsToSearch() );
        }
    }

    for(int ci=0; ci<max_cells; ci++)
    {
      const int startDepthIndex = cells[ci].getDepthToStart();
      const int nbDepthsToSearch = cells[ci].getDepthsToSearch();

      dim3 volume_slice_kernel_grid(
        divUp(volDimX, volume_slice_kernel_block.x),
        divUp(volDimY, volume_slice_kernel_block.y),
        nbDepthsToSearch);

      ALICEVISION_CU_PRINT_DEBUG("====================");
      ALICEVISION_CU_PRINT_DEBUG("RC: " << rcam.camId << ", TC: " << tcam.camId);
      ALICEVISION_CU_PRINT_DEBUG("volume_slice_kernel_grid: " << volume_slice_kernel_grid.x << ", " << volume_slice_kernel_grid.y << ", " << volume_slice_kernel_grid.z);
      ALICEVISION_CU_PRINT_DEBUG("volume_slice_kernel_block: " << volume_slice_kernel_block.x << ", " << volume_slice_kernel_block.y << ", " << volume_slice_kernel_block.z);
      ALICEVISION_CU_PRINT_DEBUG("startDepthIndex: " << startDepthIndex);
      ALICEVISION_CU_PRINT_DEBUG("nbDepthsToSearch: " << nbDepthsToSearch);
      ALICEVISION_CU_PRINT_DEBUG("startDepthIndex+nbDepthsToSearch: " << startDepthIndex+nbDepthsToSearch);
      ALICEVISION_CU_PRINT_DEBUG("volDimX: " << volDimX << ", volDimY: " << volDimY);
      ALICEVISION_CU_PRINT_DEBUG("scale-1: " << scale - 1);
      ALICEVISION_CU_PRINT_DEBUG("s: " << s);
      ALICEVISION_CU_PRINT_DEBUG("rcWidth / scale: " << rcWidth / scale << "x" << rcHeight / scale);
      ALICEVISION_CU_PRINT_DEBUG("tcWidth / scale: " << tcWidth / scale << "x" << tcHeight / scale);
      ALICEVISION_CU_PRINT_DEBUG("====================");
      Pyramid& rc_pyramid = *rcam.pyramid;
      Pyramid& tc_pyramid = *tcam.pyramid;
      cudaTextureObject_t rc_tex = rc_pyramid[scale].tex;
      cudaTextureObject_t tc_tex = tc_pyramid[scale].tex;
      volume_slice_kernel
            <<<volume_slice_kernel_grid, volume_slice_kernel_block>>>
            ( rc_tex,
              tc_tex,
              *rcam.param_dev,
              *tcam.param_dev,
              depths_d.getBuffer(),
              startDepthIndex,
              nbDepthsToSearch,
              rcWidth / scale, rcHeight / scale,
              tcWidth / scale, tcHeight / scale,
              wsh,
              gammaC, gammaP,
              gpu_volume_1st,
              volBestSim_dmp.getBytesPaddedUpToDim(1),
              volBestSim_dmp.getBytesPaddedUpToDim(0),
              gpu_volume_2nd,
              volSecBestSim_dmp.getBytesPaddedUpToDim(1),
              volSecBestSim_dmp.getBytesPaddedUpToDim(0),
              volStepXY,
              volDimX, volDimY);

        // cudaDeviceSynchronize();
        // CHECK_CUDA_ERROR();
    }

    // cudaDeviceSynchronize();
}

void ps_refineRcDepthMap(float* out_osimMap_hmh,
                         float* inout_rcDepthMap_hmh,
                         int ntcsteps,
                         CameraStruct& rc_cam,
                         CameraStruct& tc_cam,
                         int width, int height,
                         int rcWidth, int rcHeight,
                         int tcWidth, int tcHeight,
                         int scale, int CUDAdeviceNo, int ncamsAllocated,
                         bool verbose, int wsh, float gammaC, float gammaP,
                         bool moveByTcOrRc, int xFrom)
{
    // setup block and grid
    dim3 block(16, 16, 1);
    dim3 grid(divUp(width, block.x), divUp(height, block.y), 1);

    Pyramid& rc_pyramid = *rc_cam.pyramid;
    Pyramid& tc_pyramid = *tc_cam.pyramid;
    cudaTextureObject_t rc_tex = rc_pyramid[scale].tex;
    cudaTextureObject_t tc_tex = tc_pyramid[scale].tex;

    CudaDeviceMemoryPitched<float, 2> rcDepthMap_dmp(CudaSize<2>(width, height));
    copy(rcDepthMap_dmp, inout_rcDepthMap_hmh, width, height);
    CudaDeviceMemoryPitched<float, 2> bestSimMap_dmp(CudaSize<2>(width, height));
    CudaDeviceMemoryPitched<float, 2> bestDptMap_dmp(CudaSize<2>(width, height));

    clock_t tall = tic();

    for(int i = 0; i < ntcsteps; ++i) // Default ntcsteps = 31
    {
        refine_compUpdateYKNCCSimMapPatch_kernel<<<grid, block>>>(
            *rc_cam.param_dev,
            *tc_cam.param_dev,
            rc_tex, tc_tex,
            bestSimMap_dmp.getBuffer(), bestSimMap_dmp.getPitch(),
            bestDptMap_dmp.getBuffer(), bestDptMap_dmp.getPitch(),
            rcDepthMap_dmp.getBuffer(), rcDepthMap_dmp.getPitch(),
            width, height, wsh, gammaC, gammaP,
            (float)(i - (ntcsteps - 1) / 2), i, moveByTcOrRc, xFrom,
            rcWidth, rcHeight,
            tcWidth, tcHeight);
    }

    /*
    // Filter intermediate refined images does not improve
    // if(false)
    // for (int i = 0; i < 5; ++i)
    {
        // Filter refined depth map
        CudaTexture<float> depthTex(bestDptMap_dmp);
        float euclideanDelta = 1.0;
        int radius = 3;
        ps_bilateralFilter<float>(
            depthTex.textureObj,
            bestDptMap_dmp,
            euclideanDelta,
            radius);
        ps_medianFilter<float>(
            depthTex.textureObj,
            bestDptMap_dmp,
            radius);
    }
    */

    {
        CudaDeviceMemoryPitched<float3, 2> lastThreeSimsMap_dmp(CudaSize<2>(width, height));
        CudaDeviceMemoryPitched<float, 2> simMap_dmp(CudaSize<2>(width, height));

        {
            // Set best sim map into lastThreeSimsMap_dmp.y
            refine_setLastThreeSimsMap_kernel<<<grid, block>>>(
                lastThreeSimsMap_dmp.getBuffer(), lastThreeSimsMap_dmp.getPitch(),
                bestSimMap_dmp.getBuffer(), bestSimMap_dmp.getPitch(),
                width, height, 1);
            /*
            // Compute NCC for depth-1
            refine_compYKNCCSimMapPatch_kernel << <grid, block >> >(
                *rc_cam.param_dev, *tc_cam.param_dev,
                rc_tex, tc_tex,
                simMap_dmp.getBuffer(), simMap_dmp.getPitch(),
                bestDptMap_dmp.getBuffer(), bestDptMap_dmp.getPitch(),
                width,
                height, wsh, gammaC, gammaP, 0.0f, moveByTcOrRc, xFrom,
                rcWidth, rcHeight,
                tcWidth, tcHeight);
            // Set sim for depth-1 into lastThreeSimsMap_dmp.y
            refine_setLastThreeSimsMap_kernel << <grid, block >> >(
                lastThreeSimsMap_dmp.getBuffer(), lastThreeSimsMap_dmp.getPitch(),
                simMap_dmp.getBuffer(), simMap_dmp.getPitch(),
                width, height, 1);
            */
        }

        {
            // Compute NCC for depth-1
            refine_compYKNCCSimMapPatch_kernel<<<grid, block>>>(
                *rc_cam.param_dev, *tc_cam.param_dev, 
                rc_tex, tc_tex,
                simMap_dmp.getBuffer(), simMap_dmp.getPitch(),
                bestDptMap_dmp.getBuffer(), bestDptMap_dmp.getPitch(),
                width,
                height, wsh, gammaC, gammaP, -1.0f, moveByTcOrRc, xFrom,
                rcWidth, rcHeight,
                tcWidth, tcHeight);
            // Set sim for depth-1 into lastThreeSimsMap_dmp.x
            refine_setLastThreeSimsMap_kernel<<<grid, block>>>(
                lastThreeSimsMap_dmp.getBuffer(), lastThreeSimsMap_dmp.getPitch(),
                simMap_dmp.getBuffer(), simMap_dmp.getPitch(),
                width, height, 0);
        }

        {
            // Compute NCC for depth+1
            refine_compYKNCCSimMapPatch_kernel<<<grid, block>>>(
                *rc_cam.param_dev, *tc_cam.param_dev,
                rc_tex, tc_tex,
                simMap_dmp.getBuffer(), simMap_dmp.getPitch(),
                bestDptMap_dmp.getBuffer(), bestDptMap_dmp.getPitch(),
                width,
                height, wsh, gammaC, gammaP, +1.0f, moveByTcOrRc, xFrom,
                rcWidth, rcHeight,
                tcWidth, tcHeight);
            // Set sim for depth+1 into lastThreeSimsMap_dmp.z
            refine_setLastThreeSimsMap_kernel<<<grid, block>>>(
                lastThreeSimsMap_dmp.getBuffer(), lastThreeSimsMap_dmp.getPitch(),
                simMap_dmp.getBuffer(), simMap_dmp.getPitch(),
                width, height, 2);
        }

        // Interpolation from the lastThreeSimsMap_dmp
        refine_computeDepthSimMapFromLastThreeSimsMap_kernel<<<grid, block>>>(
            *rc_cam.param_dev, *tc_cam.param_dev,
            bestSimMap_dmp.getBuffer(), bestSimMap_dmp.getPitch(),
            bestDptMap_dmp.getBuffer(), bestDptMap_dmp.getPitch(),
            lastThreeSimsMap_dmp.getBuffer(), lastThreeSimsMap_dmp.getPitch(),
            width, height, moveByTcOrRc, xFrom);
    }
    copy(out_osimMap_hmh, width, height, bestSimMap_dmp);
    copy(inout_rcDepthMap_hmh, width, height, bestDptMap_dmp);

    if(verbose)
        printf("gpu elapsed time: %f ms \n", toc(tall));
}

/**
 * @brief ps_fuseDepthSimMapsGaussianKernelVoting
 * @param odepthSimMap_hmh
 * @param depthSimMaps_hmh
 * @param ndepthSimMaps: number of Tc cameras
 * @param nSamplesHalf (default value 150)
 * @param nDepthsToRefine (default value 31)
 * @param sigma
 * @param width
 * @param height
 * @param verbose
 */
void ps_fuseDepthSimMapsGaussianKernelVoting(CudaHostMemoryHeap<float2, 2>* odepthSimMap_hmh,
                                             std::vector<CudaHostMemoryHeap<float2, 2>*>& depthSimMaps_hmh, int ndepthSimMaps,
                                             int nSamplesHalf, int nDepthsToRefine, float sigma, int width, int height,
                                             bool verbose)
{
    clock_t tall = tic();

    float samplesPerPixSize = (float)(nSamplesHalf / ((nDepthsToRefine - 1) / 2));
    float twoTimesSigmaPowerTwo = 2.0f * sigma * sigma;

    ///////////////////////////////////////////////////////////////////////////////
    // setup block and grid
    int block_size = 16;
    dim3 block(block_size, block_size, 1);
    dim3 grid(divUp(width, block_size), divUp(height, block_size), 1);

    CudaDeviceMemoryPitched<float2, 2> bestDepthSimMap_dmp(CudaSize<2>(width, height));
    CudaDeviceMemoryPitched<float2, 2> bestGsvSampleMap_dmp(CudaSize<2>(width, height));
    CudaDeviceMemoryPitched<float, 2> gsvSampleMap_dmp(CudaSize<2>(width, height));
    std::vector<CudaDeviceMemoryPitched<float2, 2>*> depthSimMaps_dmp(ndepthSimMaps);

    for(int i = 0; i < ndepthSimMaps; i++)
    {
        depthSimMaps_dmp[i] = new CudaDeviceMemoryPitched<float2, 2>(CudaSize<2>(width, height));
        copy((*depthSimMaps_dmp[i]), (*depthSimMaps_hmh[i]));
    }

    for(int s = -nSamplesHalf; s <= nSamplesHalf; s++) // (-150, 150)
    {
        for(int c = 1; c < ndepthSimMaps; c++) // number of Tc cameras
        {
            fuse_computeGaussianKernelVotingSampleMap_kernel<<<grid, block>>>(
                gsvSampleMap_dmp.getBuffer(), gsvSampleMap_dmp.getPitch(),
                depthSimMaps_dmp[c]->getBuffer(), depthSimMaps_dmp[c]->getPitch(),
                depthSimMaps_dmp[0]->getBuffer(), depthSimMaps_dmp[0]->getPitch(),
                width, height, (float)s, c - 1, samplesPerPixSize, twoTimesSigmaPowerTwo);
        }
        fuse_updateBestGaussianKernelVotingSampleMap_kernel<<<grid, block>>>(
            bestGsvSampleMap_dmp.getBuffer(), bestGsvSampleMap_dmp.getPitch(),
            gsvSampleMap_dmp.getBuffer(), gsvSampleMap_dmp.getPitch(),
            width, height, (float)s, s + nSamplesHalf);
    }

    fuse_computeFusedDepthSimMapFromBestGaussianKernelVotingSampleMap_kernel<<<grid, block>>>(
        bestDepthSimMap_dmp.getBuffer(), bestDepthSimMap_dmp.getPitch(),
        bestGsvSampleMap_dmp.getBuffer(), bestGsvSampleMap_dmp.getPitch(),
        depthSimMaps_dmp[0]->getBuffer(), depthSimMaps_dmp[0]->getPitch(),
        width, height, samplesPerPixSize);

    copy((*odepthSimMap_hmh), bestDepthSimMap_dmp);

    for(int i = 0; i < ndepthSimMaps; i++)
    {
        delete depthSimMaps_dmp[i];
    }

    if(verbose)
        printf("gpu elapsed time: %f ms \n", toc(tall));
}

void ps_optimizeDepthSimMapGradientDescent(
        CudaHostMemoryHeap<float2, 2>& out_depthSimMap_hmh,
        const CudaHostMemoryHeap<float2, 2>& sgmDepthPixSizeMap_hmh,
        const CudaHostMemoryHeap<float2, 2>& refinedDepthSimMap_hmh,
        int nSamplesHalf, int nDepthsToRefine, int nIters, float sigma,
        CameraStruct& rc_cam,
        int width, int height, int scale,
        int CUDAdeviceNo, int ncamsAllocated, bool verbose, int yFrom)
{
    clock_t tall = tic();

    float samplesPerPixSize = (float)(nSamplesHalf / ((nDepthsToRefine - 1) / 2));

    ///////////////////////////////////////////////////////////////////////////////
    // setup block and grid
    int block_size = 16;
    dim3 block(block_size, block_size, 1);
    dim3 grid(divUp(width, block_size), divUp(height, block_size), 1);

    const CudaDeviceMemoryPitched<float2, 2> sgmDepthPixSizeMap_dmp(sgmDepthPixSizeMap_hmh);
    const CudaDeviceMemoryPitched<float2, 2> refinedDepthSimMap_dmp(refinedDepthSimMap_hmh);

    CudaDeviceMemoryPitched<float, 2> optDepthMap_dmp(CudaSize<2>(width, height));
    CudaDeviceMemoryPitched<float2, 2> optDepthSimMap_dmp(CudaSize<2>(width, height));
    copy(optDepthSimMap_dmp, sgmDepthPixSizeMap_dmp);

    Pyramid& rc_pyramid = *rc_cam.pyramid;
    cudaTextureObject_t rc_tex = rc_pyramid[scale].tex;

    CudaDeviceMemoryPitched<float, 2> imgVariance_dmp(CudaSize<2>(width, height));
    {
        const dim3 lblock(32, 2, 1);
        const dim3 lgrid(divUp(width, block.x), divUp(height, block.y), 1);

        compute_varLofLABtoW_kernel<<<lgrid, lblock>>>
            (rc_tex,
             imgVariance_dmp.getBuffer(), imgVariance_dmp.getPitch(),
             width, height);
    }
    CudaTexture<float> imgVarianceTex(imgVariance_dmp);

    for(int iter = 0; iter < nIters; iter++) // nIters: 100 by default
    {
        // Copy depths values from optDepthSimMap to optDepthMap
        fuse_getOptDeptMapFromOPtDepthSimMap_kernel<<<grid, block>>>(
            optDepthMap_dmp.getBuffer(), optDepthMap_dmp.getPitch(),
            optDepthSimMap_dmp.getBuffer(), optDepthSimMap_dmp.getPitch(),
            width, height);

        CudaTexture<float> depthTex(optDepthMap_dmp);

        // Adjust depth/sim by using previously computed depths
        fuse_optimizeDepthSimMap_kernel<<<grid, block>>>(
            rc_tex,
            *rc_cam.param_dev,
            imgVarianceTex.textureObj, depthTex.textureObj,
            optDepthSimMap_dmp.getBuffer(), optDepthSimMap_dmp.getPitch(),
            sgmDepthPixSizeMap_dmp.getBuffer(), sgmDepthPixSizeMap_dmp.getPitch(),
            refinedDepthSimMap_dmp.getBuffer(), refinedDepthSimMap_dmp.getPitch(),
            width, height, iter, samplesPerPixSize, yFrom);
    }

    copy(out_depthSimMap_hmh, optDepthSimMap_dmp);

    if(verbose)
        printf("gpu elapsed time: %f ms \n", toc(tall));
}

// uchar4 with 0..255 components => float3 with 0..1 components
inline __device__ __host__ float3 uchar4_to_float3(const uchar4 c)
{
    return make_float3(float(c.x) / 255.0f, float(c.y) / 255.0f, float(c.z) / 255.0f);
}

void ps_getSilhoueteMap(CudaHostMemoryHeap<bool, 2>* omap_hmh, int width,
                        int height, int scale,
                        int step,
                        CameraStruct& cam,
                        uchar4 maskColorRgb, bool verbose)
{
    clock_t tall = tic();

    uchar4 maskColorLab;
    float3 flab = xyz2lab(h_rgb2xyz(uchar4_to_float3(maskColorRgb)));
    maskColorLab.x = (unsigned char)(flab.x);
    maskColorLab.y = (unsigned char)(flab.y);
    maskColorLab.z = (unsigned char)(flab.z);
    maskColorLab.w = 0;

    // setup block and grid
    int block_size = 16;
    dim3 block(block_size, block_size, 1);
    dim3 grid(divUp(width / step, block_size), divUp(height / step, block_size), 1);

    Pyramid& pyramid = *cam.pyramid;

    CudaDeviceMemoryPitched<bool, 2> map_dmp(CudaSize<2>(width / step, height / step));
    getSilhoueteMap_kernel<<<grid, block>>>(
        pyramid[scale].tex,
        map_dmp.getBuffer(), map_dmp.getPitch(),
        step, width, height, maskColorLab);
    CHECK_CUDA_ERROR();

    copy((*omap_hmh), map_dmp);

    if(verbose)
        printf("gpu elapsed time: %f ms \n", toc(tall));
}


void ps_computeNormalMap(
    CudaHostMemoryHeap<float3, 2>& normalMap_hmh,
    CudaHostMemoryHeap<float, 2>& depthMap_hmh,
    const CameraStruct& camera, int width, int height,
    int scale, int ncamsAllocated, int scales, int wsh, bool verbose,
    float gammaC, float gammaP)
{
  clock_t tall = tic();

  CudaDeviceMemoryPitched<float, 2> depthMap_dmp(depthMap_hmh);
  CudaDeviceMemoryPitched<float3, 2> normalMap_dmp(normalMap_hmh);

  int block_size = 8;
  dim3 block(block_size, block_size, 1);
  dim3 grid(divUp(width, block_size), divUp(height, block_size), 1);

  if (verbose)
    printf("computeNormalMap_kernel\n");

  // compute normal map
  computeNormalMap_kernel<<<grid, block>>>(
    *camera.param_dev,
    depthMap_dmp.getBuffer(),
    depthMap_dmp.getPitch(),
    normalMap_dmp.getBuffer(),
    normalMap_dmp.getPitch(),
    width, height, wsh,
    gammaC, gammaP);

  // cudaThreadSynchronize();
  // CHECK_CUDA_ERROR();

  if (verbose)
    printf("copy normal map to host\n");

  copy(normalMap_hmh, normalMap_dmp);
  CHECK_CUDA_ERROR();

  if (verbose)
    printf("gpu elapsed time: %f ms \n", toc(tall));
}

void ps_loadCameraStructs( CameraStructBase*       dev,
                           const CameraStructBase* hst,
                           int                     offset )
{
    cudaMemcpyKind kind = cudaMemcpyHostToDevice;
    cudaError_t err = cudaMemcpy( &dev[offset],
                                  &hst[offset],
                                  sizeof(CameraStructBase),
                                  kind );
    THROW_ON_CUDA_ERROR( err, "Failed to copy CameraStructs from host to device in " << __FILE__ << ":" << __LINE__ << ": " << cudaGetErrorString(err) );
}

} // namespace depthMap
} // namespace aliceVision
