using Base.Test
reload("/Users/jacobquinn/julia/base/mmap2.jl")

file = tempname()
# @unix_only @test_throws SystemError Mmap2.Array(file) # requested len=0 on empty file
# @windows_only @test_throws ErrorException Mmap2.Array(file) # requested len=0 on empty file
# @unix_only @test_throws SystemError Mmap2.Array(file,0)
# @windows_only @test_throws ErrorException Mmap2.Array(file,0)
s = open(f->f,file,"w")
m = Mmap2.Array(file,12)
m[:] = "Hello World\n".data
Mmap2.sync!(m)
close(m)
@test open(readall,file) == "Hello World\n"

s = open(file, "r")
close(s)
@test_throws Base.UVError Mmap2.Array(s) # closed Mmap.Array

@test_throws SystemError Mmap2.Array("")

t = "Hello World".data
@test Mmap2.Array(UInt8, file, (11,1,1)) == reshape(t,(11,1,1))
gc(); gc()
@test Mmap2.Array(UInt8, file, (1,11,1)) == reshape(t,(1,11,1))
gc(); gc()
@test Mmap2.Array(UInt8, file, (1,1,11)) == reshape(t,(1,1,11))
gc(); gc()
m = Mmap2.Array(UInt8, file, (1,2,1))
@test m == reshape("He".data,(1,2,1))
close(m)
@test_throws SystemError Mmap2.Array(UInt8, file, (11,0,1)) # 0-dimension
@test Mmap2.Array(UInt8, file, (11,)) == t
gc(); gc()
@test Mmap2.Array(UInt8, file, (1,11)) == t'
gc(); gc()
@test_throws SystemError Mmap2.Array(UInt8, file, (0,12))

# negative length
@test_throws ArgumentError Mmap2.Array(file, -1)
# negative offset
@test_throws ArgumentError Mmap2.Array(file, 1, -1)

for i = 0x01:0x0c
    @test length(Mmap2.Array(file, i)) == Int(i)
end
gc(); gc()

sz = filesize(file)
m = Mmap2.Array(file, sz+1)
@test length(m) == sz+1 # test growing
@test m[end] == 0x00
sz = filesize(file)
close(m)
m = Mmap2.Array(file, 0, sz)
close(m)
@test isempty(m)
sz = filesize(file)
m = Mmap2.Array(file, 1, sz)
@test length(m) == 1
@test m[1] == 0x00
close(m)
sz = filesize(file)
# requesting offset > filesize(file); could we allow this to get a bunch of zeros?
@test_throws ArgumentError Mmap2.Array(file, 1, sz+1)

# s = open(file, "r")
# m = Mmap2.Array(s)
# m[5] = UInt8('x') # currently segfaults on windows, OutOfMemory on OSX
# m = nothing; gc(); gc()

s = open(file, "w")
write(s, "Hello World\n")
close(s)

# m = Mmap2.Array(file)
# open(file,"w") # errors on widnows because file is mmapped?
s = open(file, "r") # works
m = Mmap2.Array(s)
close(s)
close(m)
m = Mmap2.Array(file)
s = open(file, "r+") # works
c = Mmap2.Array(s)
d = Mmap2.Array(s)
c[1] = UInt8('J')
Mmap2.sync!(c)
close(s)
@test m[1] == UInt8('J')
close(m)
close(c)
close(d)

s = open(file, "w")
write(s, "Hello World\n")
close(s)

s = open(file, "r")
@test isreadonly(s) == true
c = Mmap2.Array(UInt8, s, (11,))
@test c == "Hello World".data
c = Mmap2.Array(UInt8, s, (UInt16(11),))
@test c == "Hello World".data
@test_throws ArgumentError Mmap2.Array(UInt8, s, (Int16(-11),))
@test_throws ArgumentError Mmap2.Array(UInt8, s, (typemax(UInt),))
close(s)
s = open(file, "r+")
@test isreadonly(s) == false
c = Mmap2.Array(UInt8, s, (11,))
c[5] = UInt8('x')
Mmap2.sync!(c)
close(s)
s = open(file, "r")
str = readline(s)
close(s)
@test startswith(str, "Hellx World")
close(c)

c = Mmap2.Array(file)
@test c == "Hellx World\n".data
close(c)
c = Mmap2.Array(file, 3)
@test c == "Hel".data
close(c)
s = open(file, "r")
c = Mmap2.Array(s, 6)
@test c == "Hellx ".data
close(s)
close(c)
c = Mmap2.Array(file, 5, 6)
@test c == "World".data
close(c)

s = open(file, "w")
write(s, "Hello World\n")
close(s)

# test Mmap2.Array
m = Mmap2.Array(file)
t = "Hello World\n"
for i = 1:12
    @test m[i] == t.data[i]
end
@test_throws BoundsError m[13]
close(m)

m = Mmap2.Array(file,6)
@test m[1] == "H".data[1]
@test m[2] == "e".data[1]
@test m[3] == "l".data[1]
@test m[4] == "l".data[1]
@test m[5] == "o".data[1]
@test m[6] == " ".data[1]
@test_throws BoundsError m[7]
close(m)
@test_throws ArgumentError m[1] # try to read unmapped-memory

m = Mmap2.Array(file,2,6)
@test m[1] == "W".data[1]
@test m[2] == "o".data[1]
@test_throws BoundsError m[3]
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
A2 = Mmap2.Array(Int, s, (m,n))
@test A == A2
close(A2)
seek(s, 0)
A3 = Mmap2.Array(Int, s, (m,n), convert(FileOffset,2*sizeof(Int)))
@test A == A3
A4 = Mmap2.Array(Int, s, (m,150), convert(FileOffset,(2+150*m)*sizeof(Int)))
@test A[:, 151:end] == A4
close(s)
close(A2); close(A3); close(A4)
rm(fname)

# other mmap tests
@test typeof(Mmap2.pagesize()) == Int
