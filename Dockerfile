FROM nvidia/cuda:13.1.0-devel-ubuntu24.04 AS build

RUN apt-get update && apt-get install -y \
    cmake build-essential git libssl-dev libcurl4-openssl-dev \
    cuda-nvcc-13-1 cuda-cudart-dev-13-1 libcublas-dev-13-2 \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/local/cuda-13.2/targets/x86_64-linux/lib/libcublas* \
              /usr/local/cuda-13.1/targets/x86_64-linux/lib/ \
    && ln -sf /usr/local/cuda-13.2/targets/x86_64-linux/lib/stubs/libcublas* \
              /usr/local/cuda-13.1/targets/x86_64-linux/lib/stubs/ \
    && ln -sf /usr/local/cuda-13.2/targets/x86_64-linux/include/cublas* \
              /usr/local/cuda-13.1/targets/x86_64-linux/include/ \
    && ln -sf /usr/local/cuda-13.2/targets/x86_64-linux/lib/static/libcublas* \
              /usr/local/cuda-13.1/targets/x86_64-linux/lib/static/ 2>/dev/null; true

WORKDIR /workspace
COPY . .

RUN cmake -B build -DGGML_CUDA=ON -DBUILD_SHARED_LIBS=OFF -DGGML_STATIC=ON \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DGGML_CUDA_FA=ON -DGGML_CUDA_FA_ALL_QUANTS=1 \
    -DCMAKE_CUDA_ARCHITECTURES=89 \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.1/bin/nvcc \
#    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    && cmake --build build --config Release --target llama-server -j$(nproc)

FROM nvidia/cuda:13.1.0-runtime-ubuntu24.04

RUN apt-get update && apt-get install -y \
    libssl3t64 libcurl4t64 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /workspace/build/bin/ /usr/local/bin/

EXPOSE 8080

ENTRYPOINT ["llama-server"]
CMD ["--host", "0.0.0.0", "--port", "8080"]
