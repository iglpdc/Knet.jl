using CUDArt
import Base: similar, copy, copy!, resize!, rand!, randn!
import Base: eltype, length, ndims, size, strides, stride, pointer, isempty, getindex, setindex!
import CUDArt: to_host

### KUdense parametrized by array type, element type, and ndims:

type KUdense{A,T,N}; arr; ptr; end

### CONSTRUCTORS

KUdense(a)=KUdense{atype(a),eltype(a),ndims(a)}(a, reshape(a, length(a)))
KUdense{A,T}(::Type{A}, ::Type{T}, d::Dims)=KUdense(A(T,d))
KUdense{A,T}(::Type{A}, ::Type{T}, d::Int...)=KUdense(A,T,d)

similar{A,T}(a::KUdense{A}, ::Type{T}, d::Dims)=KUdense(A,T,d)
similar{A,T}(a::KUdense{A,T})=KUdense(A,T,size(a))

arr(a::Vector,d::Dims)=pointer_to_array(pointer(a), d)
arr(a::CudaVector,d::Dims)=CudaArray(a.ptr, d, a.dev)

### BASIC ARRAY OPS

atype{A}(::KUdense{A})=A

for fname in (:eltype, :length, :ndims, :size, :strides, :pointer, :isempty)
    @eval $fname(a::KUdense)=$fname(a.arr)
end

for fname in (:size, :stride)
    @eval $fname(a::KUdense,n)=$fname(a.arr,n)
end

for fname in (:getindex, :setindex!)
    @eval $fname(a::KUdense,n...)=$fname(a.arr,n...)
end

### BASIC COPY

copy!{A,B,T}(a::KUdense{A,T}, b::KUdense{B,T})=(resize!(a, size(b)); copy!(a.arr, 1, b.arr, 1, length(b)); a)
copy!{A,T}(a::KUdense{A,T}, b::Union(Array{T},CudaArray{T}))=(resize!(a, size(b)); copy!(a.arr, 1, b, 1, length(b)); a)
copy(a::KUdense)=copy!(similar(a), a)

### EFFICIENT RESIZE

# Resize factor: 1.3 ensures a3 can be written where a0+a1 used to be
resizefactor(::Type{KUdense})=1.3

function resize!(a::KUdense, d::Dims)
    size(a)==d && return a
    n = prod(d)
    n > length(a.ptr) && resize!(a.ptr, int(resizefactor(KUdense)*n+1))
    a.arr = arr(a.ptr, d)
    return a
end

resize!(a::KUdense, d::Int...)=resize!(a,d)

# Need to fix deepcopy so it does not create two arrays for arr and ptr:

cpucopy_internal(x::KUdense{Array},d::ObjectIdDict)=(haskey(d,x) ? d[x] : KUdense(copy(x.arr)))
cpucopy_internal(x::KUdense{CudaArray},d::ObjectIdDict)=(haskey(d,x) ? d[x] : KUdense(to_host(x.arr)))
gpucopy_internal(x::KUdense{Array},d::ObjectIdDict)=(haskey(d,x) ? d[x] : KUdense(CudaArray(x.arr)))
gpucopy_internal(x::KUdense{CudaArray},d::ObjectIdDict)=(haskey(d,x) ? d[x] : KUdense(copy(x.arr)))

randn!{A,T}(a::KUdense{A,T}, std=one(T), mean=zero(T))=(randn!(a.arr, std, mean); a)
rand!(a::KUdense)=(rand!(a.arr); a)

to_host(a::KUdense{CudaArray})=cpucopy(a)