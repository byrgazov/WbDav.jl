using WbDav: Root, Node, FolderData, ContentData

@testset "Node{FolderData}" begin
    root = Root()

    @test root isa Node{FolderData}
    @test length(root) == 0

    @test !("test1" in root)

    push!(root, Node{ContentData}("test1"))
    push!(root, Node{ContentData}("test2"))
    push!(root, Node{FolderData}("test3"))

    @test length(root) == 3

    @test "test1" in root
    @test "test2" in root
    @test "test3" in root
    @test root[2].name == "test2"
    @test root[end].name == "test3"

    @test_throws BoundsError root[0]
    @test_throws BoundsError root[4]
end
