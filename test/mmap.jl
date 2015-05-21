file = tempname()
s = open(file, "w") do f
    write(f, "Hello World\n")
end
t = "Hello World".data
@test Mmap.Array(UInt8, file, (11,1,1)).array == reshape(t,(11,1,1))
@test Mmap.Array(UInt8, file, (1,11,1)).array == reshape(t,(1,11,1))
@test Mmap.Array(UInt8, file, (1,1,11)).array == reshape(t,(1,1,11))
@test_throws ArgumentError Mmap.Array(UInt8, file, (11,0,1)) # 0-dimension results in len=0
@test Mmap.Array(UInt8, file, (11,)).array == t
@test Mmap.Array(UInt8, file, (1,11)).array == t'
@test_throws ArgumentError Mmap.Array(UInt8, file, (0,12))
m = Mmap.Array(UInt8, file, (1,2,1))
@test m.array == reshape("He".data,(1,2,1))
close(m)

s = open(f->f,file,"w")
@test_throws ArgumentError Mmap.Array(file) # requested len=0 on empty file
@test_throws ArgumentError Mmap.Array(file,0)
m = Mmap.Array(file,12)
m.array[:] = "Hello World\n".data
Mmap.sync!(m)
close(m)
@test open(readall,file) == "Hello World\n"

s = open(file, "r")
close(s)
@test_throws Base.UVError Mmap.Array(s) # closed IOStream
@test_throws ArgumentError Mmap.Array(s,12,0) # closed IOStream
@test_throws SystemError Mmap.Array("")

# negative length
@test_throws ArgumentError Mmap.Array(file, -1)
# negative offset
@test_throws ArgumentError Mmap.Array(file, 1, -1)

for i = 0x01:0x0c
    @test length(Mmap.Array(file, i)) == Int(i)
end
gc(); gc()

sz = filesize(file)
m = Mmap.Array(file, sz+1)
@test length(m) == sz+1 # test growing
@test m.array[end] == 0x00
close(m)
sz = filesize(file)
m = Mmap.Array(file, 1, sz)
@test length(m) == 1
@test m.array[1] == 0x00
close(m)
sz = filesize(file)
# test where offset is actually > than size of file; file is grown with zeroed bytes
m = Mmap.Array(file, 1, sz+1)
@test length(m) == 1
@test m.array[1] == 0x00
close(m)

s = open(file, "r")
m = Mmap.Array(s)
@test_throws ArgumentError m[5] = UInt8('x') # tries to setindex! on read-only array
close(m)

s = open(file, "w") do f
    write(f, "Hello World\n")
end

m = Mmap.Array(file)
# open(file,"w") # errors on widnows because file is mmapped?
s = open(file, "r")
m = Mmap.Array(s)
close(s)
close(m)
m = Mmap.Array(file)
s = open(file, "r+")
c = Mmap.Array(s)
d = Mmap.Array(s)
c.array[1] = UInt8('J')
Mmap.sync!(c)
close(s)
@test m.array[1] == UInt8('J')
@test d.array[1] == UInt8('J')
close(m)
close(c)
close(d)
@test_throws ArgumentError m[1] # try to read from an mmapped-array that has been unmapped

s = open(file, "w") do f
    write(f, "Hello World\n")
end

s = open(file, "r")
@test isreadonly(s) == true
c = Mmap.Array(UInt8, s, (11,))
@test c.array == "Hello World".data
c = Mmap.Array(UInt8, s, (UInt16(11),))
@test c.array == "Hello World".data
@test_throws ArgumentError Mmap.Array(UInt8, s, (Int16(-11),))
@test_throws ArgumentError Mmap.Array(UInt8, s, (typemax(UInt),))
close(s)
s = open(file, "r+")
@test isreadonly(s) == false
c = Mmap.Array(UInt8, s, (11,))
c.array[5] = UInt8('x')
Mmap.sync!(c)
close(s)
s = open(file, "r")
str = readline(s)
close(s)
@test startswith(str, "Hellx World")
close(c)

c = Mmap.Array(file)
@test c.array == "Hellx World\n".data
close(c)
c = Mmap.Array(file, 3)
@test c.array == "Hel".data
close(c)
s = open(file, "r")
c = Mmap.Array(s, 6)
@test c.array == "Hellx ".data
close(s)
close(c)
c = Mmap.Array(file, 5, 6)
@test c.array == "World".data
close(c)

s = open(file, "w")
write(s, "Hello World\n")
close(s)

# test Mmap.Array
m = Mmap.Array(file)
t = "Hello World\n"
for i = 1:12
    @test m.array[i] == t.data[i]
end
@test_throws BoundsError m[13]
close(m)

m = Mmap.Array(file,6)
@test m.array[1] == "H".data[1]
@test m.array[2] == "e".data[1]
@test m.array[3] == "l".data[1]
@test m.array[4] == "l".data[1]
@test m.array[5] == "o".data[1]
@test m.array[6] == " ".data[1]
@test_throws BoundsError m.array[7]
close(m)
@test_throws ArgumentError m[1] # try to read unmapped-memory

m = Mmap.Array(file,2,6)
@test m.array[1] == "W".data[1]
@test m.array[2] == "o".data[1]
@test_throws BoundsError m.array[3]
close(m)
@test_throws ArgumentError m[1]

# mmap with an offset
A = rand(1:20, 500, 300)
fname = tempname()
s = open(fname, "w+")
write(s, size(A,1))
write(s, size(A,2))
write(s, A)
close(s)
s = open(fname)
m = read(s, Int)
n = read(s, Int)
A2 = Mmap.Array(Int, s, (m,n))
@test A == A2.array
close(A2)
seek(s, 0)
A3 = Mmap.Array(Int, s, (m,n), convert(FileOffset,2*sizeof(Int)))
@test A == A3.array
A4 = Mmap.Array(Int, s, (m,150), convert(FileOffset,(2+150*m)*sizeof(Int)))
@test A[:, 151:end] == A4.array
close(s)
close(A2); close(A3); close(A4)
rm(fname)

# AnonymousMmap
m = Mmap.AnonymousMmap()
@test m.name == ""
@test !m.readonly
@test m.create
@test isopen(m)
@test isreadable(m)
@test iswritable(m)

m = Mmap.Array(UInt8, 12)
@test length(m) == 12
@test all(m .== 0x00)
@test m[1] === 0x00
@test m[end] === 0x00
m[1] = 0x0a
Mmap.sync!(m)
@test m[1] === 0x0a
close(m)
@test_throws ArgumentError (m[1] = 0x00)
@test_throws ArgumentError m[5]
m = Mmap.Array(UInt8, 12; shared=false)
m = Mmap.Array(Int, 12)
@test length(m) == 12
@test all(m .== 0)
@test m[1] === 0
@test m[end] === 0
m = Mmap.Array(Float64, 12)
@test length(m) == 12
@test all(m .== 0.0)
m = Mmap.Array(Int8, (12,12))
@test size(m) == (12,12)
@test all(m == zeros(Int8, (12,12)))
@test iswritable(m)
@test isreadable(m)
@test sizeof(m) == prod((12,12))
n = similar(m)
@test typeof(n) <: Mmap.Array{Int8,2}
@test all(n .== Int8(0))
@test size(n) == (12,12)
n = similar(m, (2,2))
@test typeof(n) <: Mmap.Array{Int8,2}
@test all(n .== Int8(0))
@test size(n) == (2,2)
n = similar(m, 12)
@test length(n) == 12
@test size(n) == (12,)
@test all(n .== Int8(0))
@test typeof(n) <: Mmap.Array{Int8,1}
n = similar(m, UInt8)
@test typeof(n) <: Mmap.Array{UInt8,2}
@test size(n) == size(m)
@test eltype(n) == UInt8
@test all(n .== 0x00)
m = Mmap.zeros(UInt8, 12)
@test all(n .== m)

# Array interface tests
m = Mmap.Array(file)
@test size(m) == (12,)
@test length(m) == 12
@test ndims(m) == 1
@test endof(m) == 12
@test first(m) == 0x48
@test last(m) == 0x0a
@test sizeof(m) == 12
@test eltype(m) == UInt8
@test Base.elsize(m) == 1

@test !isempty(m)

@test all(copy(m) .== m)

n = similar(m)
copy!(n,m)
@test all(n .== m)

fill!(n, 0x00)
@test all(n .== 0x00)

# iteration
for i in n
    @test i == 0x00
end

@test 0x00 in n

@test reverse(m) == reverse("Hello World\n".data)
@test map(x->x*0x02, m) == map(x->x*0x02,"Hello World\n".data)

n = Mmap.Array(file)
@test m == n
mn = vcat(m,n)
@test length(mn) == length(m) + length(n)
@test mn[1:length(m)] == m
@test mn[length(m)+1:end] == n
@test size(mn) == (24,)
m_n = hcat(m,n)
@test size(m_n) == (12,2)
@test m_n[:,1] == m
@test m_n[:,2] == n

@test m .* n == "Hello World\n".data .* "Hello World\n".data
@test m .+ n == "Hello World\n".data .* 2
@test m * 2 == m .+ m
@test n / 2 == "Hello World\n".data / 2

f = float(m)
@test eltype(f) == Float64

n = Mmap.Array(file, (2,6))
n_r = reshape(n, (12,))
@test all([i for i in n] .== [i for i in n_r])
