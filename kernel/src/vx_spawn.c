// Copyright © 2019-2023
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <inttypes.h>
#include <vx_print.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NUM_CORES_MAX 1024

#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif

typedef struct {
	vx_spawn_tasks_cb callback;
	void* arg;
	int offset; // task offset
  int remain; // remaining offset
	int FWs;    // number of NW batches where NW=<total warps per core>.
	int RWs;    // number of remaining warps in the core  
} wspawn_tasks_args_t;

typedef struct {
  pocl_kernel_context_t * ctx;
  pocl_kernel_cb callback;
  void* arg;
	int local_size;
  int offset; // task offset
  int remain; // remaining offset
	int FWs;    // number of NW batches where NW=<total warps per core>.
	int RWs;    // number of remaining warps in the core  
  char isXYpow2;
  char log2XY;
  char log2X;
} wspawn_pocl_kernel_args_t;

inline char is_log2(int x) {
  return ((x & (x-1)) == 0);
}

inline int log2_fast(int x) {
  return 31 - __builtin_clz (x);
}

static void __attribute__ ((noinline)) spawn_tasks_all_stub() {
  int NT  = vx_num_threads();
  int wid = vx_warp_id();
  int tid = vx_thread_id();

  wspawn_tasks_args_t* p_wspawn_args = (wspawn_tasks_args_t*)csr_read(VX_CSR_MSCRATCH);

  int wK = (p_wspawn_args->FWs * wid) + MIN(p_wspawn_args->RWs, wid);
  int tK = p_wspawn_args->FWs + (wid < p_wspawn_args->RWs);
  int offset = p_wspawn_args->offset + (wK * NT) + tid;

  vx_spawn_tasks_cb callback = p_wspawn_args->callback;
  void* arg = p_wspawn_args->arg;
  for (int task_id = offset, N = offset + tK * NT; task_id < N; task_id += NT) {
    callback(task_id, arg);
  }
}

static void __attribute__ ((noinline)) spawn_tasks_rem_stub() {
  int tid = vx_thread_id();
  
  wspawn_tasks_args_t* p_wspawn_args = (wspawn_tasks_args_t*)csr_read(VX_CSR_MSCRATCH);
  int task_id = p_wspawn_args->remain + tid;
  (p_wspawn_args->callback)(task_id, p_wspawn_args->arg);
}

static void __attribute__ ((noinline)) spawn_tasks_all_cb() {  
  // activate all threads
  vx_tmc(-1);

  // call stub routine
  spawn_tasks_all_stub();

  // disable warp
  vx_tmc_zero();
}

void vx_spawn_tasks(int num_tasks, vx_spawn_tasks_cb callback , void * arg) {
	// device specs
  int NC = vx_num_cores();
  int NW = vx_num_warps();
  int NT = vx_num_threads();

  // current core id
  int core_id = vx_core_id();
  if (core_id >= NUM_CORES_MAX)
    return;

  // calculate necessary active cores
  int WT = NW * NT;
  int nC = (num_tasks > WT) ? (num_tasks / WT) : 1;
  int nc = MIN(nC, NC);
  if (core_id >= nc)
    return; // terminate extra cores

  // number of tasks per core
  int tasks_per_core = num_tasks / nc;
  int tasks_per_core_n1 = tasks_per_core;  
  if (core_id == (nc-1)) {    
    int rem = num_tasks - (nc * tasks_per_core); 
    tasks_per_core_n1 += rem; // last core also executes remaining tasks
  }

  // number of tasks per warp
  int TW = tasks_per_core_n1 / NT;      // occupied warps
  int rT = tasks_per_core_n1 - TW * NT; // remaining threads
  int fW = 1, rW = 0;
  if (TW >= NW) {
    fW = TW / NW;			                  // full warps iterations
    rW = TW - fW * NW;                  // remaining warps
  }

  int offset = core_id * tasks_per_core;
  int remain = offset + (tasks_per_core_n1 - rT);

  wspawn_tasks_args_t wspawn_args = {callback, arg, offset, remain, fW, rW};
  csr_write(VX_CSR_MSCRATCH, &wspawn_args);

	if (TW >= 1)	{
    // execute callback on other warps
    int nw = MIN(TW, NW);
	  vx_wspawn(nw, spawn_tasks_all_cb);

    // activate all threads
    vx_tmc(-1);

    // call stub routine
    spawn_tasks_all_stub();
  
    // back to single-threaded
    vx_tmc_one();
	}  

  if (rT != 0) {
    // activate remaining threads  
    int tmask = (1 << rT) - 1;
    vx_tmc(tmask);

    // call stub routine
    spawn_tasks_rem_stub();

    // back to single-threaded
    vx_tmc_one();
  }
    
  // wait for spawn warps to terminate
  vx_wspawn_wait();
}

///////////////////////////////////////////////////////////////////////////////

static void __attribute__ ((noinline)) spawn_pocl_kernel_all_stub() {
  int NT  = vx_num_threads();
  int wid = vx_warp_id();
  int tid = vx_thread_id();

  wspawn_pocl_kernel_args_t* p_wspawn_args = (wspawn_pocl_kernel_args_t*)csr_read(VX_CSR_MSCRATCH);
  pocl_kernel_context_t* ctx = p_wspawn_args->ctx;
  void* arg = p_wspawn_args->arg;

  int wK = (p_wspawn_args->FWs * wid) + MIN(p_wspawn_args->RWs, wid);
  int tK = p_wspawn_args->FWs + (wid < p_wspawn_args->RWs);
  int offset = p_wspawn_args->offset + (wK * NT) + tid;

  int X = ctx->num_groups[0];
  int Y = ctx->num_groups[1];
  int XY = X * Y;

  if (p_wspawn_args->isXYpow2) {
    for (int wg_id = offset, N = wg_id + tK * NT; wg_id < N; wg_id += NT ) {
      int k = wg_id >> p_wspawn_args->log2XY;
      int wg_2d = wg_id - k * XY;
      int j = wg_2d >> p_wspawn_args->log2X;
      int i = wg_2d - j * X;
      int local_offset = wg_id * p_wspawn_args->local_size;
      (p_wspawn_args->callback)(arg, ctx, i, j, k, local_offset);
    }
  } else {
    for (int wg_id = offset, N = wg_id + tK * NT; wg_id < N; wg_id += NT ) {
      int k = wg_id / XY;
      int wg_2d = wg_id - k * XY;
      int j = wg_2d / X;
      int i = wg_2d - j * X;
      int local_offset = wg_id * p_wspawn_args->local_size;
      (p_wspawn_args->callback)(arg, ctx, i, j, k, local_offset);
    }
  }
}

static void __attribute__ ((noinline)) spawn_pocl_kernel_rem_stub() {
  int tid = vx_thread_id();

  wspawn_pocl_kernel_args_t* p_wspawn_args = (wspawn_pocl_kernel_args_t*)csr_read(VX_CSR_MSCRATCH);
  pocl_kernel_context_t* ctx = p_wspawn_args->ctx;
  void* arg = p_wspawn_args->arg;

  int X = ctx->num_groups[0];
  int Y = ctx->num_groups[1];
  int XY = X * Y;

  int wg_id = p_wspawn_args->remain + tid;
  int local_offset = wg_id * p_wspawn_args->local_size;

  if (p_wspawn_args->isXYpow2) {
    int k = wg_id >> p_wspawn_args->log2XY;
    int wg_2d = wg_id - k * XY;
    int j = wg_2d >> p_wspawn_args->log2X;
    int i = wg_2d - j * X;
    (p_wspawn_args->callback)(arg, ctx, i, j, k, local_offset);
  } else {
    int k = wg_id / XY;
    int wg_2d = wg_id - k * XY;
    int j = wg_2d / X;
    int i = wg_2d - j * X;
    (p_wspawn_args->callback)(arg, ctx, i, j, k, local_offset);
  }
}

static void __attribute__ ((noinline)) spawn_pocl_kernel_all_cb() {  
  // activate all threads
  vx_tmc(-1);

  // call stub routine
  spawn_pocl_kernel_all_stub();

  // disable warp
  vx_tmc_zero();
}

void vx_spawn_pocl_kernel(pocl_kernel_context_t * ctx, pocl_kernel_cb callback, void * arg) {  
  // total number of WGs
  int X  = ctx->num_groups[0];
  int Y  = ctx->num_groups[1];
  int Z  = ctx->num_groups[2];
  int XY = X * Y;
  int num_tasks = XY * Z;
  
  // device specs
  int NC = vx_num_cores();
  int NW = vx_num_warps();
  int NT = vx_num_threads();

  // current core id
  int core_id = vx_core_id();  
  if (core_id >= NUM_CORES_MAX)
    return;

  // calculate necessary active cores
  int WT = NW * NT;
  int nC = (num_tasks > WT) ? (num_tasks / WT) : 1;
  int nc = MIN(nC, NC);
  if (core_id >= nc)
    return; // terminate extra cores

  // number of tasks per core
  int tasks_per_core = num_tasks / nc;
  int tasks_per_core_n1 = tasks_per_core;  
  if (core_id == (nc-1)) {    
    int rem = num_tasks - (nc * tasks_per_core); 
    tasks_per_core_n1 += rem; // last core also executes remaining WGs
  }

  // number of tasks per warp
  int TW = tasks_per_core_n1 / NT;      // occupied warps
  int rT = tasks_per_core_n1 - TW * NT; // remaining threads
  int fW = 1, rW = 0;
  if (TW >= NW) {
    fW = TW / NW;			                  // full warps iterations
    rW = TW - fW * NW;                  // remaining warps
  }

  // fast path handling
  char isXYpow2 = is_log2(XY);
  char log2XY   = log2_fast(XY);
  char log2X    = log2_fast(X);

  int local_size = ctx->local_size[0] * ctx->local_size[1] * ctx->local_size[2];
  int offset = core_id * tasks_per_core;
  int remain = offset + (tasks_per_core_n1 - rT);

  wspawn_pocl_kernel_args_t wspawn_args = { 
    ctx, callback, arg, local_size, offset, remain, fW, rW, isXYpow2, log2XY, log2X
  };
  csr_write(VX_CSR_MSCRATCH, &wspawn_args);

	if (TW >= 1)	{
    // execute callback on other warps
    int nw = MIN(TW, NW);
	  vx_wspawn(nw, spawn_pocl_kernel_all_cb);

    // activate all threads
    vx_tmc(-1);

    // call stub routine
    spawn_pocl_kernel_all_stub();

    // back to single-threaded
    vx_tmc_one();
	}  

  if (rT != 0) {
    // activate remaining threads
    int tmask = (1 << rT) - 1;
    vx_tmc(tmask);

    // call stub routine
    spawn_pocl_kernel_rem_stub();

    // back to single-threaded
    vx_tmc_one();
  }
    
  // wait for spawn warps to terminate
  vx_wspawn_wait();
}

#ifdef __cplusplus
}
#endif
