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
    common_files: map[string]b32,
}

Tag     :: "common"
TagFile :: `common="file"`
Input   :: `D:\handmade\code\game`

OutputDir  :: `D:\handmade\code\`
OutputFile :: `generated.odin`
OutputPackage :: "main"

Header :: 
`package %v
 ///////////////////////////////////////////////
 //////////////////IMPORTANT////////////////////
 ///////////////////////////////////////////////
 ////                                       ////
 ////  THIS CODE IS GENERATED. DO NOT EDIT  ////
 ////                                       ////
 ///////////////////////////////////////////////
 
`

extract_common_game_declarations :: proc() {
    using my_context: ExtractContext
    
    context.user_ptr = &my_context
    
    fi, _ := os2.read_directory_by_path(Input, -1, context.allocator)
    for f in fi {
        bytes, _ := os2.read_entire_file_from_path(f.fullpath, context.allocator)
        files[f.fullpath] = string(bytes)
    }
    context.user_ptr = &files
    
    Output := fmt.tprint(OutputDir, OutputFile, sep="")
    if os.exists(Output) {
        os.remove(Output)
    }
    out, _ := os.open(Output, os.O_CREATE)
    defer os.close(out)
    fmt.fprintfln(out, Header, OutputPackage)
    
    v := ast.Visitor{ visit = extract_commons }
    
    pkg, ok := parser.parse_package_from_path(Input)
    assert(ok)
    
    ast.walk(&v, pkg)

    for key, it in imports {
        if common_files[it.location.file] != true {
            fmt.fprintfln(out, "// @Copypasta from %s(%d:%d)\n%s\n", it.location.file, it.location.line, it.location.column, it.content)
        }
    }
    
    for key, it in declarations {
        if common_files[it.location.file] != true {
            fmt.fprintfln(out, "// @Copypasta from %s(%d:%d)\n%s\n", it.location.file, it.location.line, it.location.column, it.content)
        }
    }
    
    for key, _ in common_files {
        path, _ := strings.replace(key, Input, OutputDir, 1, context.temp_allocator)
        path, _ = strings.replace(path, ".odin", "-generated.odin", 1, context.temp_allocator)
        
        header := fmt.tprintf(Header, OutputPackage)
        
        data := files[key]
        corrected, _ := strings.replace(data, "package game", header, -1, context.temp_allocator)
        corrected, _ = strings.replace(corrected, `@(common="file")`, "", -1, context.temp_allocator)
        os.write_entire_file(path, transmute([]u8) corrected)
    }
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
    using my := cast(^ExtractContext) context.user_ptr
    
    for attribute in attributes {
        if len(attribute.elems) > 0 {
            is_marked_as_common: b32
            other_attributes: [dynamic]string
            name, name_and_body: string
            
            for expr in attribute.elems {
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
                    } else if strings.equal_fold(att_name, TagFile) {
                        common_files[attribute.node.pos.file] = true
                        return
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
