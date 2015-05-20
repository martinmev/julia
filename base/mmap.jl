# This file is a part of Julia. License is MIT: http://julialang.org/license

module Mmap

# platform-specific mmap utilities
pagesize() = Int(@unix ? ccall(:jl_getpagesize, Clong, ()) : ccall(:jl_getallocationgranularity, Clong, ()))

@unix_only begin
const SEEK_SET = Cint(0)
const SEEK_CUR = Cint(1)
const SEEK_END = Cint(2)
# Before mapping, grow the file to sufficient size
# (Required if you're going to write to a new memory-mapped file)
#
# Note: a few mappable streams do not support lseek. When Julia
# supports structures in ccall, switch to fstat.
function grow!(io::IO, offset::FileOffset, len::Integer)
    # Save current file position so we can restore it later
    pos = position(io)
    filelen = filesize(io)
    if filelen < offset + len
        write(io, zeros(UInt8,(offset + len) - filelen))
        flush(io)
    end
    seek(io, pos)
    return
end

const PROT_READ  = Cint(1)
const PROT_WRITE = Cint(2)
const MAP_SHARED = Cint(1)
const F_GETFL    = Cint(3)
# Determine a stream's read/write mode, and return prot & flags
# appropriate for mmap
# We could use isreadonly here, but it's worth checking that it's readable too
function settings(s)
    mode = ccall(:fcntl,Cint,(Cint,Cint),s,F_GETFL)
    systemerror("fcntl F_GETFL", mode == -1)
    mode = mode & 3
    prot = mode == 0 ? PROT_READ : mode == 1 ? PROT_WRITE : PROT_READ | PROT_WRITE
    if prot & PROT_READ == 0
        throw(ArgumentError("mmap requires read permissions on the file (choose r+)"))
    end
    flags = MAP_SHARED
    return prot, flags, (prot & PROT_WRITE) > 0
end
end # @unix_only

@windows_only begin
type SharedMemSpec <: IO
    name::AbstractString
    readonly::Bool
    create::Bool
end

Base.fd(sh::SharedMemSpec) = -2 # -1 == INVALID_HANDLE_VALUE

const INVALID_HANDLE_VALUE = -1
gethandle(io::SharedMemSpec) = INVALID_HANDLE_VALUE
function gethandle(io::IO)
    handle = Base._get_osfhandle(RawFD(fd(io))).handle
    systemerror("could not get handle for file to map: $(Base.FormatMessage())", handle == -1)
    return Int(handle)
end

settings(sh::SharedMemSpec) = utf16(sh.name), sh.readonly, sh.create
settings(io::IO) = Ptr{Cwchar_t}(C_NULL), isreadonly(io), true

# Memory mapped file constants
const PAGE_READONLY          = UInt32(0x02)
const PAGE_READWRITE         = UInt32(0x04)
const PAGE_WRITECOPY         = UInt32(0x08)

const PAGE_EXECUTE_READ      = UInt32(0x20)
const PAGE_EXECUTE_READWRITE = UInt32(0x40)
const PAGE_EXECUTE_WRITECOPY = UInt32(0x80)

const FILE_MAP_COPY          = UInt32(0x01)
const FILE_MAP_WRITE         = UInt32(0x02)
const FILE_MAP_READ          = UInt32(0x04)
const FILE_MAP_EXECUTE       = UInt32(0x20)
end # @windows_only

# core impelementation of mmap
type Array{T,N} <: AbstractArray{T,N}
    array::Base.Array{T,N} # array of memory-mapped data; *May only refer to `ptr+offset:ptr+length(array)`
    ptr::Ptr{Void}         # pointer to start of memory-mapped data, points to start of a page boundary
    handle::Ptr{Void}      # only needed on windows for file mapping object
    isreadable::Bool
    iswritable::Bool

    function Mmap.Array{T,N}(::Type{T}, io::IO, dims::NTuple{N,Integer}=(filesize(io),), offset::Integer=position(io); grow::Bool=true)
        # check inputs
        isopen(io) || throw(ArgumentError("$io must be open to mmap"))
        applicable(fd,io) || throw(ArgumentError("method `fd(::$T)` doesn't exist, unable to mmap $io"))
        applicable(filesize,io) || throw(ArgumentError("method `filesize(::$T)` doesn't exist, unable to mmap $io"))

        len = prod(dims) * sizeof(T)
        len > 0 || throw(ArgumentError("requested size must be > 0, got $len"))
        ps = Mmap.pagesize()
        len < typemax(Int)-ps || throw(ArgumentError("requested size must be < $(typemax(Int)-ps), got $len"))

        offset >= 0 || throw(ArgumentError("requested offset must be ≥ 0, got $offset"))

        # shift `offset` to start of page boundary
        offset_page::FileOffset = div(offset, ps) * ps
        # add (offset - offset_page) to `len` to get total length of memory-mapped region
        len_page = (offset - offset_page) + len

        # platform-specific internals
         @unix_only begin
            file_desc = fd(io)
            prot, flags, iswrite = Mmap.settings(file_desc)
            iswrite && grow && Mmap.grow!(io, offset, len)
            # mmap the file
            ptr = ccall(:jl_mmap, Ptr{Void}, (Ptr{Void}, Csize_t, Cint, Cint, Cint, FileOffset), C_NULL, len_page, prot, flags, file_desc, offset_page)
            systemerror("memory mapping failed", reinterpret(Int,ptr) == -1)
            handle = C_NULL
        end # @unix_only

        @windows_only begin
            hdl::Int = gethandle(io)
            name, readonly, create = settings(io)
            szfile = convert(Csize_t, len + offset)
            readonly && szfile > filesize(io) && throw(ArgumentError("unable to increase file size to $szfile due to read-only permissions"))
            handle = create ? ccall(:CreateFileMappingW, stdcall, Ptr{Void}, (Cptrdiff_t, Ptr{Void}, Cint, Cint, Cint, Cwstring),
                                    hdl, C_NULL, readonly ? PAGE_READONLY : PAGE_READWRITE, szfile >> 32, szfile & typemax(UInt32), name) :
                                  ccall(:OpenFileMappingW, stdcall, Ptr{Void}, (Cint, Cint, Cwstring),
                                    readonly ? FILE_MAP_READ : FILE_MAP_WRITE, true, name)
            handle == C_NULL && error("could not create file mapping: $(Base.FormatMessage())")
            ptr = ccall(:MapViewOfFile, stdcall, Ptr{Void}, (Ptr{Void}, Cint, Cint, Cint, Csize_t),
                            handle, readonly ? FILE_MAP_READ : FILE_MAP_WRITE, offset_page >> 32, offset_page & typemax(UInt32), (offset - offset_page) + len)
            ptr == C_NULL && error("could not create mapping view: $(Base.FormatMessage())")
        end # @windows_only
        # convert mmapped region to Julia Array at `ptr + (offset - offset_page)` since file was mapped at offset_page
        A = pointer_to_array(convert(Ptr{T}, UInt(ptr) + (offset - offset_page)), dims)
        array = new{T,N}(A,ptr,handle,isreadable(io),iswritable(io))
        finalizer(array,close)
        return array
    end
end

Mmap.Array{T,N}(::Type{T}, file::AbstractString, dims::NTuple{N,Integer}=(filesize(file),), offset::Integer=Int64(0); grow::Bool=true) =
    open(io->Mmap.Array(T, io, dims, offset; grow=grow), file, isfile(file) ? "r+" : "w+")

# using default type: UInt8
Mmap.Array{N}(io::IO, dims::NTuple{N,Integer}=(filesize(io),), offset::Integer=position(io); grow::Bool=true) =
    Mmap.Array(UInt8, io, dims, offset; grow=grow)
Mmap.Array{N}(file::AbstractString, dims::NTuple{N,Integer}=(filesize(io),), offset::Integer=Int64(0); grow::Bool=true) =
    open(io->Mmap.Array(UInt8, io, dims, offset; grow=grow), file, isfile(file) ? "r+" : "w+")

# using a length argument instead of dims
Mmap.Array(io::IO, len::Integer=filesize(io), offset::Integer=position(io); grow::Bool=true) =
    Mmap.Array(UInt8, io, (len,), offset; grow=grow)
Mmap.Array(file::AbstractString, len::Integer=filesize(file), offset::Integer=Int64(0); grow::Bool=true) =
    open(io->Mmap.Array(UInt8, io, (len,), offset; grow=grow), file, isfile(file) ? "r+" : "w+")

function Base.close(m::Mmap.Array)
    m.isreadable = false; m.iswritable = false
    @unix_only systemerror("munmap", ccall(:munmap,Cint,(Ptr{Void},Int),m.ptr,length(m.array)) != 0)
    @windows_only begin
        status = ccall(:UnmapViewOfFile, stdcall, Cint, (Ptr{Void},), m.ptr)!=0
        status |= ccall(:CloseHandle, stdcall, Cint, (Ptr{Void},), m.handle)!=0
        status || error("could not unmap view: $(Base.FormatMessage())")
    end
    return
end

Base.iswritable(m::Mmap.Array) = m.iswritable
Base.isreadable(m::Mmap.Array) = m.isreadable

# limited Array interface
Base.length(m::Mmap.Array) = length(m.array)
Base.size(m::Mmap.Array) = size(m.array)

const READERROR  = ArgumentError("mapped-memory is not readable")
Base.getindex(S::Mmap.Array) = isreadable(S) ? getindex(S.array) : throw(READERROR)
Base.getindex(S::Mmap.Array, I::Real) = isreadable(S) ? getindex(S.array, I) : throw(READERROR)
Base.getindex(S::Mmap.Array, I::AbstractArray) = isreadable(S) ? getindex(S.array, I) : throw(READERROR)
@generated function Base.getindex(S::Mmap.Array, I::Union(Real,AbstractVector)...)
    N = length(I)
    Isplat = Expr[:(I[$d]) for d = 1:N]
    quote
        isreadable(S) ? getindex(S.array, $(Isplat...)) : throw(READERROR)
    end
end

const WRITEERROR = ArgumentError("mapped-memory is not writable")
Base.setindex!(S::Mmap.Array, x) = iswritable(S) ? setindex!(S.array, x) : throw(WRITEERROR)
Base.setindex!(S::Mmap.Array, x, I::Real) = iswritable(S) ? setindex!(S.array, x, I) : throw(WRITEERROR)
Base.setindex!(S::Mmap.Array, x, I::AbstractArray) = iswritable(S) ? setindex!(S.array, x, I) : throw(WRITEERROR)
@generated function Base.setindex!(S::Mmap.Array, x, I::Union(Real,AbstractVector)...)
    N = length(I)
    Isplat = Expr[:(I[$d]) for d = 1:N]
    quote
        iswritable(S) ? setindex!(S.array, x, $(Isplat...)) : throw(WRITEERROR)
    end
end

# msync flags for unix
const MS_ASYNC = 1
const MS_INVALIDATE = 2
const MS_SYNC = 4

function sync!(m::Mmap.Array, flags::Integer=MS_SYNC)
    @unix_only systemerror("msync", ccall(:msync, Cint, (Ptr{Void}, Csize_t, Cint), pointer(m.array), length(m), flags) != 0)
    @windows_only systemerror("could not FlushViewOfFile: $(Base.FormatMessage())",
                    ccall(:FlushViewOfFile, stdcall, Cint, (Ptr{Void}, Csize_t), pointer(m.array), length(m)) == 0)
end

end # module