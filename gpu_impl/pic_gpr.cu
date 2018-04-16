// System includes
#include <stdio.h>
#include <iostream>
#include <assert.h>

// CUDA runtime
#include <cuda_runtime.h>
#include "cublas.h"

#include <math.h>
#include <string.h>
#include "operators.hpp"
#include "operators.cuh"

#define NUM_SLAVES 5
#define CARD_SUPPORT_SET 20

// to compute local summary (running on GPU)
__global__ void slave_local(int N, float *S, float *D, float *yD, float *U, float *local_M, float *local_C) {
    int samples = S.n_rows;
    __shared__ float *SD, *DD, *DS, *SS, *inv_DD_S;

    // host copies
    float *a, *b, **out;

    // device copies
    float *d_a, *d_b, *d_out;

    int s = 4 * sizeof(float*);

    // Allocate space for device copies
    cudaMalloc((void **)&d_a, s);
    cudaMalloc((void **)&d_b, s);
    cudaMalloc((void **)&d_out, s);

    // Calculate for local summary
    // SD = covariance(S, D, Kernel);
    // DD = covariance(D, D, Kernel);
    // DS = covariance(D, S, Kernel);
    // SS = covariance(S, S, Kernel);

    a[0] = S; b[0] = D;
    a[1] = D; b[1] = D;
    a[2] = D; b[2] = S;
    a[3] = S; b[3] = S;

    // copy inputs to device
    cudaMemcpy(d_a, &a, s, cudaMemcpyHostToDevice);
    cudaMemcpy(d_b, &b, s, cudaMemcpyHostToDevice);
    cudaMemcpy(d_out, &out, s, cudaMemcpyHostToDevice);

    // execute 4 covariance functions in parallel using 4 blocks
    cov<<<4,1>>>(d_a, d_b, N, d_out);

    // synchronice all device functions
    cudaDeviceSynchronize();

    // copy outputs to host
    cudaMemcpy(out, d_out, s, cudaMemcpyDeviceToHost);

    SD = out[0];
    DD = out[1];
    DS = out[2];
    SS = out[3];

    // calculate local summary
    inv_DD_S = inv(DD-DS*inv(SS, N)*SD, N);
    local_M = SD*inv_DD_S*yD;
    local_C = SD*inv_DD_S*DS;
}

// to calculate for global summary (running on GPU)
__global__ void slave_global(int N, float *S, float *D, float *yD, float *U, float *local_C, float *global_C, float *global_M, float *pred_mean) {
    extern __shared__ float *SD, *DD, *DS, *SS, *inv_DD_S;

    // local copies
    float *a, *b, *out;

    // device copies
    float *d_a, *d_b, *d_out;

    int s = 5 * sizeof(float*);

    // Allocate space for device copies
    cudaMalloc((void **)&d_a, s);
    cudaMalloc((void **)&d_b, s);
    cudaMalloc((void **)&d_out, s);

    // Calculate for global summary
    // mat UU = covariance(U, U, Kernel);
    // mat US = covariance(U, S, Kernel);
    // mat SU = covariance(S, U, Kernel);
    // mat UD = covariance(U, D, Kernel);
    // mat DU = covariance(D, U, Kernel);

    a[0] = U; b[0] = U;
    a[1] = U; b[1] = S;
    a[2] = S; b[2] = U;
    a[3] = U; b[3] = D;
    a[4] = D; b[4] = U;

    // copy inputs to device
    cudaMemcpy(d_a, &a, s, cudaMemcpyHostToDevice);
    cudaMemcpy(d_b, &b, s, cudaMemcpyHostToDevice);
    cudaMemcpy(d_out, &out, s, cudaMemcpyHostToDevice);

    // execute 5 covariance functions in parallel using 5 blocks
    cov<<<5,1>>>(d_a, d_b, N, d_out);

    // copy outputs to host
    cudaMemcpy(out, d_out, s, cudaMemcpyDeviceToHost);

    float *UU = out[0];
    float *US = out[1];
    float *SU = out[2];
    float *UD = out[3];
    float *DU = out[4];

    // calculate global summary
    float *local_US = UD*inv_DD_S*DS;
    float *local_SU = SD*inv_DD_S*DU;
    float *local_UU = UD*inv_DD_S*DU;
    float *pred_mean = US*inv(global_C, N)*global_M; //(Phi_US*inv(global_C, N)*global_M) + UD*inv_DD_S*yD;
    float *pred_covar = UU - US * (inv(SS, N) - inv(global_C, N))*SU; //UU-(Phi_US*inv(SS, N)*SU-US*inv(SS, N)*local_SU-Phi_US*inv(global_C, N)*trans(Phi_US))-local_UU;

    // predictions stored in pred_mean
}

// master runs on CPU
void master(mat S, int** pred, int* partition, mat train_data, mat train_target, mat test_data, mat test_target, int interval) {
    int	slaveCount;
    int samples = S.n_rows;
    float *test_mean, *test_covar;

    float *global_M = new float[samples];
    float *global_C = new float[samples];

    float *train_data_arr = new float[NUM_SLAVES];
    float *train_target_arr = new float[NUM_SLAVES];
    float *test_data_arr = new float[NUM_SLAVES];

    float **local_M_arr = new float[NUM_SLAVES];
    float **local_C_arr = new float[NUM_SLAVES];

    cudaStream_t *streams;
    int s = sizeof(float);

    // start NUM_SLAVES workers to calculate for local summary
    for (slaveCount = 0; slaveCount < NUM_SLAVES; slaveCount++) {
        // partitions
        train_data_arr[slaveCount] = matToArray(train_data.rows(slaveCount*interval, (slaveCount+1)*interval-1));
        train_target_arr[slaveCount] = matToArray(train_target.rows(slaveCount*interval, (slaveCount+1)*interval-1));
        test_data_arr[slaveCount] = matToArray(test_data.rows(slaveCount*interval, (slaveCount+1)*interval-1));

        // device copies
        float *d_support, *d_train_data, *d_train_target, *d_test_data, *local_M, *local_C;

        // Allocate space for device copies
        cudaMalloc((void **)&d_support, s);
        cudaMalloc((void **)&d_train_data, s);
        cudaMalloc((void **)&d_train_target, s);
        cudaMalloc((void **)&d_test_data, s);

        cudaMalloc((void **)&local_M, s);
        cudaMalloc((void **)&local_C, s);

        // Copy inputs to device
        cudaMemcpy(d_support, &S, s, cudaMemcpyHostToDevice);
        cudaMemcpy(d_train_data, &train_data_arr[slaveCount], s, cudaMemcpyHostToDevice);
        cudaMemcpy(d_train_target, &train_target_arr[slaveCount], s, cudaMemcpyHostToDevice);
        cudaMemcpy(d_test_data, &test_data_arr[slaveCount], s, cudaMemcpyHostToDevice);

        // create new stream for parallel grid execution
        cudaStreamCreate(&streams[slaveCount]);

        // launch one worker(slave) kernel per stream
        slave_local<<<1, 1, 0, streams[slaveCount]>>>(partition[slaveCount], d_support, d_train_data, d_train_target, d_test_data, local_M, local_C);

        // Copy result back to host
        cudaMemcpy(&local_M_arr[slaveCount], local_M, s, cudaMemcpyDeviceToHost);
        cudaMemcpy(&local_C_arr[slaveCount], local_C, s, cudaMemcpyDeviceToHost);

        // Cleanup
        cudaFree(d_support); cudaFree(d_train_data); cudaFree(d_train_target); cudaFree(d_test_data);
    }

    // synchronice all device functions
    cudaDeviceSynchronize();

    // sum up local summary to get global summary
    for (slaveCount = 0; slaveCount < NUM_SLAVES; slaveCount++) {
        global_M = global_M + local_M_arr[slaveCount];
        global_C = global_C + local_C_arr[slaveCount];
    }

    // calculate for final prediction
    for (slaveCount = 0; slaveCount < NUM_SLAVES; slaveCount++) {
        // device copies
        float *d_support, *d_train_data, *d_train_target, *d_test_data, *local_C;
        float *d_global_M, *d_global_C;
        double *d_pred_M;

        // Allocate space for device copies
        cudaMalloc((void **)&d_support, s);
        cudaMalloc((void **)&d_train_data, s);
        cudaMalloc((void **)&d_train_target, s);
        cudaMalloc((void **)&d_test_data, s);
        cudaMalloc((void **)&local_C, s);

        cudaMalloc((void **)&d_global_M, s);
        cudaMalloc((void **)&d_global_C, s);
        cudaMalloc((void **)&d_pred_M, s);

        // Copy inputs to device
        cudaMemcpy(d_support, &S, s, cudaMemcpyHostToDevice);
        cudaMemcpy(d_train_data, &train_data_arr[slaveCount], s, cudaMemcpyHostToDevice);
        cudaMemcpy(d_train_target, &train_target_arr[slaveCount], s, cudaMemcpyHostToDevice);
        cudaMemcpy(d_test_data, &test_data_arr[slaveCount], s, cudaMemcpyHostToDevice);
        cudaMemcpy(local_C, &local_C_arr[slaveCount], s, cudaMemcpyHostToDevice);

        cudaMemcpy(d_global_M, &global_M, s, cudaMemcpyHostToDevice);
        cudaMemcpy(d_global_C, &global_C, s, cudaMemcpyHostToDevice);

        // launch one worker(slave) kernel per stream, reuse stream to access shared variables
        slave_global<<<1, 1, 0, streams[slaveCount]>>>(partition[slaveCount], d_support, d_train_data, d_train_target, d_test_data, local_C, d_global_M, d_global_C, d_pred_M);

        // Copy result back to host
        cudaMemcpy(&pred[slaveCount], d_pred_M, sizeof(double), cudaMemcpyDeviceToHost);

        // Cleanup
        cudaFree(d_support); cudaFree(d_train_data); cudaFree(d_train_target); cudaFree(d_test_data); cudaFree(local_C);
        cudaFree(d_global_M); cudaFree(d_global_C); cudaFree(d_pred_M);
    }

    // synchronice all device functions
    cudaDeviceSynchronize();

    // results are in pred (int** pred)
    cout<<"Done"<<endl;
}

// main runs on CPU
int main(int argc, char *argv[]){
    // load data from csv file
    std::string path = "data.csv";
    mat data = parseCsvFile(path, 1000);

    // normalise the dataset
    int rows = data.n_rows;
    int columns = data.n_cols;

    mat Max = max(data, 0);
    mat Min = min(data, 0);

    for(int i=0;i<rows;i++){
        // ignore the last target column
        for(int j=1;j<columns; j++){
            data(i,j) = (data(i,j)-Min(0, j))/Max(0, j);
        }
    }

    // split data into training and testing samples
    int all_samples = data.n_rows;
    mat train_data = data.rows(0, all_samples/2-1).cols(1, 8);
    mat train_target = data.rows(0, all_samples/2-1).col(0);
    mat test_data = data.rows(all_samples/2, all_samples-1).cols(1, 8);
    mat test_target = data.rows(all_samples/2, all_samples-1).col(0);

    int *pred = new int[all_samples-all_samples/2];

    // get the support data set and partitions of training data set
    mat support;
    int partitions[NUM_SLAVES+1];
    int intervals = all_samples/(2*NUM_SLAVES);
    for(int i=0;i<NUM_SLAVES;i++){
        partitions[i+1] = all_samples/(2*NUM_SLAVES);
        int idx = i*intervals;
        for(int j=0;j<CARD_SUPPORT_SET/NUM_SLAVES;j++){
            support.insert_rows(0, train_data.row(idx+j));
        }
    }

    // call master function (execute on CPU) to start slaves (working on GPU)
    master(support, &pred, partitions, train_data, train_target, test_data, test_target, intervals);

    // print out predictions in pred variable
    mat pred_M = zeros<mat>(all_samples-all_samples/2, 1);
    for(int i = 0; i < (all_samples-all_samples/2); i++){
        cout << pred[i] << "(" << test_target(i, 0) << ")" << "\t";
        if(i%10==0 && i!=0){
            cout<<endl;
        }
        pred_M(i, 0) = pred[i];
    }
    return(0);
}
