#+private
package build

import "core:fmt"
import "core:strings"
import "core:os"
import "core:os/os2"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"

Code :: struct {
    content: string, 
    location: tokenizer.Pos,
}

ExtractContext :: struct {
    files:        map[string]string,
    imports:      map[string]Code,
    declarations: map[string]Code,
}

Tag    :: "common"
Inputs :: [?]string{`D:\handmade\code\game`}
Output :: `D:\handmade\code\generated.odin`
OutputPackage :: "main"

extract_common_game_declarations :: proc() {
    using my_context: ExtractContext
    context.user_ptr = &my_context
    
    for input in Inputs {
        fi, _ := os2.read_directory_by_path(input, -1, context.allocator)
        for f in fi {
            bytes, _ := os2.read_entire_file_from_path(f.fullpath, context.allocator)
            files[f.fullpath] = string(bytes)
        }
    }
    context.user_ptr = &files
    
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
    
    v := ast.Visitor{ visit = extract_commons }
    
    for input in Inputs {
        pkg, ok := parser.parse_package_from_path(input)
        assert(ok)
        
        ast.walk(&v, pkg)
    }
    for key, it in imports      do fmt.fprintfln(out, "// @Copypasta from %s(%d:%d)\n%s\n", it.location.file, it.location.line, it.location.column, it.content)
    for key, it in declarations do fmt.fprintfln(out, "// @Copypasta from %s(%d:%d)\n%s\n", it.location.file, it.location.line, it.location.column, it.content)
}

extract_commons :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
    using my := cast(^ExtractContext) context.user_ptr
    
    if node == nil do return visitor
    
    #partial switch decl in node.derived {
    case ^ast.Value_Decl:
        collect(&declarations, decl.attributes[:], decl.pos, decl.end)
    case ^ast.Import_Decl:
        collect(&imports, decl.attributes[:], decl.pos, decl.end)
    }
    return visitor
}

collect :: proc(collect: ^map[string]Code, attributes: []^ast.Attribute, pos, end: tokenizer.Pos) {
    for attritbute in attributes {
        if len(attritbute.elems) > 0 {
            is_marked_as_common: b32
            other_attributes: [dynamic]string
            name, name_and_body: string
            
            for expr in attritbute.elems {
                if att_name, ok := read_pos(expr.pos, expr.end); ok {
                    if strings.equal_fold(att_name, Tag) {
                        is_marked_as_common = true
                        ok: bool
                        name_and_body, ok = read_pos(pos, end)
                        
                        eon : int
                        for _, i in name_and_body {
                            if i > 0 && name_and_body[i-1] == ':' && name_and_body[i] == ':' do break
                            eon = i
                        }
                        name = name_and_body[:eon]
                        
                        assert(ok)
                    } else {
                        append(&other_attributes, fmt.tprint(att_name))
                    }
                }
            }
            
            if is_marked_as_common {
                builder: string
                
                if len(other_attributes) > 0 {
                    builder = fmt.tprint(builder, "@(", sep = "")
                    for other in other_attributes do builder = fmt.tprint(builder, other, ",", sep = "")
                    builder = fmt.tprint(builder, ")\n", sep = "")
                }
                builder = fmt.tprint(builder, name_and_body, sep = "")
                
                collect[name] = {
                    content = builder,
                    location = pos,
                }
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
