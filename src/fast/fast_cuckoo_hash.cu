/*
 *  fast_cuckoo_hash.hpp
 *
 *  Created on: 01-06-2015
 *      Author: Karol Dzitkowski
 *
 *  >>  Real-time Parallel Hashing on the GPU
 *
 *  Implementation of a fast cuckoo hashing method introduced in publication:
 *
 *  Dan A. Alcantara, Andrei Sharf, Fatemeh Abbasinejad, Shubhabrata Sengupta,
 *  Michael Mitzenmacher, John D. Owens, and Nina Amenta "Real-time Parallel
 *  Hashing on the GPU", ACM Transactions on Graphics
 *  (Proceedings of ACM SIGGRAPH Asia 2009)
 *
 *  which can be found here http://idav.ucdavis.edu/~dfalcant/research/hashing.php
 */

#include "fast_cuckoo_hash.cuh"
#include "hash_function.cuh"
#include "helpers.h"
#include "macros.h"
#include <thrust/scan.h>
#include <cuda_runtime_api.h>

__global__ void divideKernel(
		const int2* values,
		const int size,
		const Constants<2> constants,
		unsigned int* counts,
		const int bucket_cnt,
		unsigned int* offsets,
		const unsigned int max_size,
		bool* failure)
{
	unsigned idx = threadIdx.x + blockIdx.x * blockDim.x +
			blockIdx.y * blockDim.x * gridDim.x;

	if(idx >= size) return;

	int key = values[idx].x;
	unsigned hash = bucketHashFunction(
			constants.values[0], constants.values[1], key, bucket_cnt);
	offsets[idx] = atomicAdd(&counts[hash], 1);
	if(offsets[idx] == max_size - 1) *failure = true;
}

__global__ void copyKernel(
		const int2* values,
		const int size,
		const Constants<2> constants,
		unsigned int* starts,
		const int bucket_cnt,
		unsigned int* offsets,
		int2* buffer)
{
	unsigned idx = threadIdx.x + blockIdx.x * blockDim.x +
			blockIdx.y * blockDim.x * gridDim.x;

	if(idx >= size) return;

	int key = values[idx].x;
	unsigned hash = bucketHashFunction(
			constants.values[0], constants.values[1], key, bucket_cnt);
	unsigned point = starts[hash] + offsets[idx];
	buffer[point] = values[idx];
}

bool splitToBuckets(
		int2* values,
		const int size,
		const Constants<2> constants,
		const int bucket_cnt,
		const int block_size,
		unsigned int* starts,
		unsigned int* counts,
		int2* result)
{
	auto grid = CuckooHash<2>::GetGrid(size);
	int blockSize = CuckooHash<2>::DEFAULT_BLOCK_SIZE;

	bool h_failure;
	bool* d_failure;
	unsigned int* d_offsets;
	CUDA_CALL( cudaMalloc((void**)&d_offsets, size*sizeof(unsigned int)) );
	CUDA_CALL( cudaMalloc((void**)&d_failure, sizeof(bool)) );

	divideKernel<<<grid, blockSize>>>(
			values, size, constants, counts,
			bucket_cnt, d_offsets, block_size, d_failure);

	cudaDeviceSynchronize();
	CUDA_CALL( cudaMemcpy(&h_failure, d_failure, sizeof(bool), cudaMemcpyDeviceToHost) );
	CUDA_CALL( cudaFree(d_failure) );

	if(h_failure == false)
	{
		thrust::device_ptr<unsigned int> starts_ptr(starts);
		thrust::device_ptr<unsigned int> counts_ptr(counts);
		auto end = thrust::exclusive_scan(counts_ptr, counts_ptr+bucket_cnt, starts_ptr);

		copyKernel<<<grid, blockSize>>>(
				values, size, constants, starts, bucket_cnt, d_offsets, result);
		cudaDeviceSynchronize();
	}

	CUDA_CALL( cudaFree(d_offsets) );
	return !h_failure;
}

__global__ void insertKernel(
		const int2* valuesArray,
		const unsigned int* starts,
		const unsigned int* counts,
		const int arrId,
		int2* hashMap,
		const int bucket_size,
		Constants<3> constants,
		const unsigned max_iters,
		bool* failure)
{
	unsigned i, hash;
	unsigned idx = threadIdx.x;
	unsigned idx2 = idx + blockDim.x;
	extern __shared__ int2 s[];

	// GET DATA
	const int2* values = valuesArray + starts[arrId];
	const int size = counts[arrId];
	int2* hashMap_part = hashMap + (bucket_size * arrId);

	// COPY HASH MAP TO SHARED MEMORY
	s[idx] = hashMap_part[idx];
	if(idx2 < bucket_size) s[idx2] = hashMap_part[idx2];
	__syncthreads();

	if(idx < size)
	{
		int2 value = values[idx];
		for(i = 1; i <= max_iters; i++)
		{
			hash = hashFunction(constants.values[i%3], value.x, bucket_size);
			int2 old_value = s[hash];	// read old value
			__syncthreads();
			s[hash] = value;			// write new value
			__syncthreads();
			if(value.x == s[hash].x)	// check for success
			{
				if(old_value.x == EMPTY_BUCKET_KEY) break;
				else value = old_value;
			}
		}
		if(i == max_iters) *failure = true;
	}

	// COPY SHARED MEMORY TO HASH MAP
	__syncthreads();
	if(idx2 < bucket_size) s[idx2] = hashMap_part[idx2];
	hashMap_part[idx] = s[idx];
}

bool fast_cuckooHash(
		int2* values,
		const int in_size,
		int2* hashMap,
		const int bucket_cnt,
		Constants<2> bucket_constants,
		Constants<3> constants,
		int max_iters)
{
	const int block_size = FAST_CUCKOO_HASH_BLOCK_SIZE;
	unsigned int* starts;
	unsigned int* counts;
	int2* buckets;
	bool* d_failure;
	bool h_failure;

	// CREATE STREAMS
	cudaStream_t* streams = new cudaStream_t[bucket_cnt];
	for(int i=0; i<bucket_cnt; i++)
		CUDA_CALL( cudaStreamCreate(&streams[i]) );

	// ALLOCATE MEMORY
	CUDA_CALL( cudaMalloc((void**)&starts, bucket_cnt*sizeof(unsigned int)) );
	CUDA_CALL( cudaMalloc((void**)&counts, bucket_cnt*sizeof(unsigned int)) );
	CUDA_CALL( cudaMalloc((void**)&buckets, in_size*sizeof(int2)) );
	CUDA_CALL( cudaMalloc((void**)&d_failure, sizeof(bool)) );

	bool splitResult = splitToBuckets(
			values, in_size, bucket_constants, bucket_cnt,
			block_size, starts, counts, buckets);

	if(splitResult)
	{
		const int shared_mem_size = PART_HASH_MAP_SIZE * sizeof(int2);
		for(int i=0; i<bucket_cnt; i++)
		{
			insertKernel<<<block_size, 1, shared_mem_size, streams[i]>>>(
					values, starts, counts, i, hashMap,
					PART_HASH_MAP_SIZE, constants, max_iters, d_failure);
		}
		cudaDeviceSynchronize();
		CUDA_CALL( cudaMemcpy(&h_failure, d_failure, sizeof(bool), cudaMemcpyDeviceToHost) );
	} else return false;

	// FREE MEMORY
	CUDA_CALL( cudaFree(starts) );
	CUDA_CALL( cudaFree(counts) );
	CUDA_CALL( cudaFree(buckets) );
	CUDA_CALL( cudaFree(d_failure) );
	for(int i=0; i<bucket_cnt; i++) CUDA_CALL( cudaStreamDestroy(streams[i]) );
	delete [] streams;

	return h_failure;
}

__global__ void toInt2Kernel(const int* keys, const int size, int2* out)
{
	unsigned idx = threadIdx.x + blockIdx.x * blockDim.x +
				blockIdx.y * blockDim.x * gridDim.x;

	if(idx >= size) return;
	out[idx].x = keys[idx];
	out[idx].y = idx; // SAVE OLD POSITION
}

__global__ void retrieveKernel(
		int2* buckets,
		int2* hashMap,
		const unsigned int* starts,
		const unsigned int* counts,
		const int arrId,
		const int bucket_size,
		Constants<3> constants,
		int2* out)
{
	unsigned idx = threadIdx.x;

	// GET DATA
	const int2 value = (buckets + starts[arrId])[idx];
	const int size = counts[arrId];
	int2* hashMap_part = hashMap + (bucket_size * arrId);

	if(idx >= size) return;
	int2 entry;
	unsigned hash;

	#pragma unroll
	for(int i = 0; i < 3; i++)
	{
		hash = hashFunction(constants.values[i], value.x, bucket_size);
		entry = hashMap_part[hash];
		if(entry.x == value.x) break;
	}

	if(entry.x != value.x) entry = int2{EMPTY_BUCKET_KEY, EMPTY_BUCKET_KEY};

	// PLACE IT ON OLD POSITION
	out[value.y] = entry;
}

int2* fast_cuckooRetrieve(
		const int* keys,
		const int size,
		int2* hashMap,
		const int bucket_cnt,
		const Constants<2> bucket_constants,
		const Constants<3> constants)
{
	auto grid = CuckooHash<2>::GetGrid(size);
	int blockSize = CuckooHash<2>::DEFAULT_BLOCK_SIZE;
	const int block_size = FAST_CUCKOO_HASH_BLOCK_SIZE;

	// ALLOCATE MEMORY
	int2 *result, *buckets;
	unsigned int *starts, *counts;
	CUDA_CALL( cudaMalloc((void**)&result, size*sizeof(int2)) );
	CUDA_CALL( cudaMalloc((void**)&starts, bucket_cnt*sizeof(unsigned int)) );
	CUDA_CALL( cudaMalloc((void**)&counts, bucket_cnt*sizeof(unsigned int)) );
	CUDA_CALL( cudaMalloc((void**)&buckets, size*sizeof(int2)) );

	// CREATE STREAMS
	cudaStream_t* streams = new cudaStream_t[bucket_cnt];
	for(int i=0; i<bucket_cnt; i++)
		CUDA_CALL( cudaStreamCreate(&streams[i]) );

	// SPLIT TO BUCKETS
	toInt2Kernel<<<grid, blockSize>>>(keys, size, result);
	cudaDeviceSynchronize();
	bool splitResult = splitToBuckets(
			result, size, bucket_constants, bucket_cnt, block_size, starts, counts, buckets);

	// RETRIEVE VALUES
	if(splitResult)
	{
		for(int i=0; i<bucket_cnt; i++)
		{
			retrieveKernel<<<block_size, 1, 0, streams[i]>>>(
					buckets, hashMap, starts, counts, i, PART_HASH_MAP_SIZE, constants, result);
		}
		cudaDeviceSynchronize();
	}
	// FREE MEMORY
	CUDA_CALL( cudaFree(starts) );
	CUDA_CALL( cudaFree(counts) );
	CUDA_CALL( cudaFree(buckets) );
	for(int i=0; i<bucket_cnt; i++) CUDA_CALL( cudaStreamDestroy(streams[i]) );
	delete [] streams;

	return result;
}
