#+private
package build

import "core:fmt"
import "core:strings"
import "core:os"
import "core:os/os2"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"

ExtractContext :: struct {
    files: map[string]string,
    imports: [dynamic]string,
    declarations: [dynamic]string,
}

Tag    :: "common"
Input  :: `D:\handmade\code\game`
Output :: `D:\handmade\code\generated.odin`
OutputPackage :: "main"

extract_common_game_declarations :: proc() {
    using my_context: ExtractContext
    context.user_ptr = &my_context
    
    fi, _ := os2.read_directory_by_path(Input, -1, context.allocator)
    for f in fi {
        bytes, _ := os2.read_entire_file_from_path(f.fullpath, context.allocator)
        files[f.fullpath] = string(bytes)
    }
    context.user_ptr = &files
    
    pkg, ok := parser.parse_package_from_path(Input)
    assert(ok)
    
    if os.exists(Output) {
        os.remove(Output)
    }
    out, _ := os.open(Output, os.O_CREATE)
    defer os.close(out)
    fmt.fprintfln(out, `
package %v
///////////////////////////////////////////////
//////////////////IMPORTANT////////////////////
///////////////////////////////////////////////
////                                       ////
////  THIS CODE IS GENERATED. DO NOT EDIT  ////
////                                       ////
///////////////////////////////////////////////

`, OutputPackage)
    v := ast.Visitor{
        visit = extract_commons
    }
    ast.walk(&v, pkg)
    for imp in imports do fmt.fprint(out, imp)
    for decl in declarations do fmt.fprint(out, decl)
    
    fmt.fprintln(out, "\n")
}

extract_commons :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
    using my := cast(^ExtractContext) context.user_ptr
    
    if node == nil do return visitor
    #partial switch decl in node.derived {
    case ^ast.Value_Decl:
        foo(&declarations, decl.attributes[:], decl.pos, decl.end)
    case ^ast.Import_Decl:
        foo(&imports, decl.attributes[:], decl.pos, decl.end)
    }
    return visitor
}

foo :: proc(collect: ^[dynamic]string, attributes: []^ast.Attribute, pos, end: tokenizer.Pos) {
    for attritbute in attributes {
        if len(attritbute.elems) > 0 {
            is_marked_as_common: b32
            other_attributes: [dynamic]string
            declaration: string
            
            for expr in attritbute.elems {
                if att_name, ok := read_pos(expr.pos, expr.end); ok {
                    if strings.equal_fold(att_name, Tag) {
                        is_marked_as_common = true
                        decl_name, ok := read_pos(pos, end)
                        assert(ok)
                        declaration = fmt.tprint(decl_name)
                    } else {
                        append(&other_attributes, fmt.tprint(att_name))
                    }
                }
            }
            
            if is_marked_as_common {
                if len(other_attributes) > 0 {
                    append(collect, "@(") 
                    for other in other_attributes do append(collect, other, ",")
                    append(collect, ")\n")
                }
                append(collect, declaration, "\n")
            }
        }
    }
}


read_pos :: proc(start, end: tokenizer.Pos) -> (result:string, ok:bool) {
    using my := cast(^ExtractContext) context.user_ptr
    
    file: string
    file, ok = files[start.file]
    ok &= start.file==end.file
    if ok {
        result = file[start.offset:end.offset]
    } else {
        if start.file==end.file {
            fmt.println("unknown file:", start.file)
        } else {
            fmt.println("bad pos:", start, end)
        }
    }
    return
}
