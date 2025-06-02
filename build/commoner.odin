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
    exports:      map[string]Code,
}

CommonTag     :: `common`
CommonTagFile :: `common="file"`
ExportTag     :: `export`
Input         :: `D:\handmade\code\game`

extract_common_and_exports :: proc() {
    using my_context: ExtractContext
    context.user_ptr = &my_context
    
    fi, _ := os2.read_directory_by_path(Input, -1, context.allocator)
    for f in fi {
        bytes, _ := os2.read_entire_file_from_path(f.fullpath, context.allocator)
        files[f.fullpath] = string(bytes)
    }
    
    input_package, ok := parser.parse_package_from_path(Input)
    assert(ok)
    
    output_package := "main"
    
    extract_common_game_declarations(input_package, `D:\handmade\code\`, `generated.odin`,         output_package)
    extract_exports_and_generate_api(input_package, `D:\handmade\code\`, `exports-generated.odin`, output_package)
}

Header :: 
`#+vet !unused-procedures
#+no-instrumentation
package %v
///////////////////////////////////////////////
//////////////////@important///////////////////
///////////////////////////////////////////////
////                                       ////
////  THIS CODE IS GENERATED. DO NOT EDIT  ////
////                                       ////
///////////////////////////////////////////////
 
`

extract_exports_and_generate_api :: proc(pkg: ^ast.Package, output_dir, output_file, output_package: string) {
    using my := cast(^ExtractContext) context.user_ptr
    
    v := ast.Visitor{ visit = visit_and_extract_exports }
    ast.walk(&v, pkg)
    
    output := fmt.tprint(output_dir, output_file, sep="")
    if os.exists(output) do os.remove(output)
    out, _ := os.open(output, os.O_CREATE)
    defer os.close(out)
    fmt.fprintfln(out, Header, output_package)
    
    no_stubs: map[string]b32
    no_stubs["output_sound_samples"] = true
    no_stubs["update_and_render"] = true
    
    fmt.fprint(out, `
import win "core:sys/windows"

game_stubs :: GameApi {`)
    for key, it in exports {
        if no_stubs[key] do continue
        fmt.fprintf(out, `
    %s = %s %s,`, key, it.content, `{ return }`)

    }
    fmt.fprint(out, `
}
`)

    fmt.fprint(out, `
GameApi :: struct {`)
    for key, it in exports {
        fmt.fprintf(out, `
    %s: %s,`, key, strings.to_pascal_case(key))
    }
    fmt.fprint(out, `
}
`)

    fmt.fprint(out, `
load_game_api :: proc(game_lib: win.HMODULE) {`)
        for key, it in exports {
            fmt.fprintf(out, `
    game.%s = auto_cast win.GetProcAddress(game_lib, "%s")`, key, key)
        }
    fmt.fprint(out, `
}
`)
    
    
    for key, it in exports {
        fmt.fprintf(out, `
// @copypasta Exported from %s(%d:%d)
%s :: #type %s`, it.location.file, it.location.line, it.location.column, strings.to_pascal_case(key), it.content)
    }
    
}

extract_common_game_declarations :: proc(pkg: ^ast.Package, output_dir, output_file, output_package: string) {
    using my := cast(^ExtractContext) context.user_ptr
    
    output := fmt.tprint(output_dir, output_file, sep="")
    if os.exists(output) do os.remove(output)
    out, _ := os.open(output, os.O_CREATE)
    defer os.close(out)
    fmt.fprintfln(out, Header, output_package)
    
    v := ast.Visitor{ visit = visit_and_extract_commons }
    ast.walk(&v, pkg)
    
    for key, it in imports {
        if common_files[it.location.file] != true {
            fmt.fprintfln(out, "// @copypasta from %s(%d:%d)\n%s\n", it.location.file, it.location.line, it.location.column, it.content)
        }
    }
    
    for key, it in declarations {
        if common_files[it.location.file] != true {
            fmt.fprintfln(out, "// @copypasta from %s(%d:%d)\n%s\n", it.location.file, it.location.line, it.location.column, it.content)
        }
    }
    
    for key, _ in common_files {
        path, _ := strings.replace(key, Input, output_dir, 1, context.temp_allocator)
        path, _ = strings.replace(path, ".odin", "-generated.odin", 1, context.temp_allocator)
        
        header := fmt.tprintf(Header, output_package)
        
        data := files[key]
        corrected, _ := strings.replace(data, "package game", header, -1, context.temp_allocator)
        corrected, _ = strings.replace(corrected, `@(common="file")`, "", -1, context.temp_allocator)
        os.write_entire_file(path, transmute([]u8) corrected)
    }
}

// @todo(viktor): maybe compress the exports with the common as there is a lot of shared code
visit_and_extract_exports :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
    using my := cast(^ExtractContext) context.user_ptr
    
    if node == nil do return visitor
    
    #partial switch decl in node.derived {
      case ^ast.Value_Decl:
        collect_exports(&exports, decl.attributes[:], decl.pos, decl.end)
    }
    return visitor
}

collect_exports :: proc(collect: ^map[string]Code, attributes: []^ast.Attribute, pos, end: tokenizer.Pos) {
    using my := cast(^ExtractContext) context.user_ptr
    
    for attribute in attributes {
        if len(attribute.elems) > 0 {
            is_export: b32
            other_attributes: [dynamic]string
            name, declaration: string
            
            for expr in attribute.elems {
                if att_name, ok := read_pos(expr.pos, expr.end); ok {
                    if strings.equal_fold(att_name, ExportTag) {
                        is_export = true
                        ok: bool
                        declaration, ok = read_pos(pos, end)
                        assert(ok)
                        
                        eon, eoh: int
                        for _, i in declaration {
                            if i+1 < len(declaration) && declaration[i] == ':' && declaration[i+1] == ':' {
                                eon = i
                            }
                            if i+1 < len(declaration) && declaration[i+1] == '{' {
                                eoh = i
                                break
                            }
                        }
                        
                        name = strings.trim_right_space(declaration[:eon])
                        declaration = declaration[eon+2:eoh]
                        
                    // } else if strings.equal_fold(att_name, CommonTagFile) {
                    //     common_files[attribute.node.pos.file] = true
                    //     return
                    } else {
                        append(&other_attributes, fmt.tprint(att_name))
                    }
                }
            }
            
            if is_export {
                builder: string
                
                if len(other_attributes) > 0 {
                    builder = fmt.tprint(builder, "@(", sep = "")
                    for other in other_attributes do builder = fmt.tprint(builder, other, ",", sep = "")
                    builder = fmt.tprint(builder, ")\n", sep = "")
                }
                builder = fmt.tprint(builder, declaration, sep = "")
                
                collect[name] = {
                    content = builder,
                    location = pos,
                }
            }
        }
    }
}

visit_and_extract_commons :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
    using my := cast(^ExtractContext) context.user_ptr
    
    if node == nil do return visitor
    
    #partial switch decl in node.derived {
      case ^ast.Value_Decl:
        collect_declarations(&declarations, decl.attributes[:], decl.pos, decl.end)
      case ^ast.Import_Decl:
        collect_declarations(&imports, decl.attributes[:], decl.pos, decl.end)
    }
    return visitor
}

collect_declarations :: proc(collect: ^map[string]Code, attributes: []^ast.Attribute, pos, end: tokenizer.Pos) {
    using my := cast(^ExtractContext) context.user_ptr
    
    for attribute in attributes {
        if len(attribute.elems) > 0 {
            is_marked_as_common: b32
            other_attributes: [dynamic]string
            name, name_and_body: string
            
            for expr in attribute.elems {
                if att_name, ok := read_pos(expr.pos, expr.end); ok {
                    if strings.equal_fold(att_name, CommonTag) {
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
                    } else if strings.equal_fold(att_name, CommonTagFile) {
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


read_pos :: proc(start, end: tokenizer.Pos) -> (result: string, ok: bool) {
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
