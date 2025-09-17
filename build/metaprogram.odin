#+private
package build

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:os/os2"
import "core:slice"
import "core:strings"
import "core:terminal/ansi"

Info :: struct { 
    name: string, 
    type: string, 
    location: tokenizer.Pos
}

Metaprogram :: struct {
    files: map[string]string,
    
    common_declarations: map[string] [dynamic] Info,
    common_files: map[string] ^ast.File,
    exports: [dynamic] Info,
    
    apis: map[string] [dynamic] Info,
    
    
    printlikes: map[string]Printlike,
    procedures: map[string]Procedure,
}

metaprogram_collect_data :: proc(using mp: ^Metaprogram, dir: string) -> (success: b32) {
    context.user_ptr = mp
    
    collect_all_files(&files, dir)
    
    pack, ok := parser.parse_package_from_path(dir)
    if !ok {
        fmt.printfln("ERROR: The metaprogram failed to parse the package %v", dir)
        return false
    }
    
    files: for file_name, file in pack.files {
        for tag in file.tags {
            if tag.text == "#+private file" {
                continue files
            }
        }
        
        for declaration, declaration_index in file.decls {
            #partial switch declaration in declaration.derived_stmt {
            case ^ast.Value_Decl:
                if !declaration.is_mutable {
                    if has_attribute(declaration.attributes[:], "api") {
                        assert(len(declaration.values) == 1)
                        value := declaration.values[0]
                            
                        assert(len(declaration.names) == 1)
                        name := declaration.names[0]
                        ident := name.derived_expr.(^ast.Ident)
                        
                        procedure := value.derived_expr.(^ast.Proc_Lit)
                        type := read_pos_or_fail(procedure.type.pos, procedure.type.end)
                            
                        file, ok := &apis[declaration.pos.file]
                        if !ok {
                            apis[declaration.pos.file] = {}
                            file = &apis[declaration.pos.file]
                        }
                        
                        append(file, Info {
                            name = ident.name,
                            type = type,
                            location = declaration.pos,
                        })
                    }
                    
                    if has_attribute(declaration.attributes[:], "export") {
                        assert(len(declaration.attributes) == 1)
                        assert(len(declaration.values) == 1)
                        value := declaration.values[0]
                        procedure := value.derived_expr.(^ast.Proc_Lit)
                        assert(len(declaration.names) == 1)
                        name := declaration.names[0]
                        ident := name.derived_expr.(^ast.Ident)
                        
                        append(&exports, Info {
                            name = ident.name,
                            type = read_pos_or_fail(procedure.type.pos, procedure.type.end),
                            location = declaration.pos,
                        })
                    }
                    
                    if has_attribute(declaration.attributes[:], `common="file"`) {
                        assert(declaration_index == 0)
                        append_common_file(&common_files, &common_declarations, file)
                    }
                    
                    if has_attribute(declaration.attributes[:], "common") {
                        if file.fullpath not_in common_files {
                            entries, ok := &common_declarations[file.fullpath]
                            if !ok {
                                common_declarations[file.fullpath] = {}
                                entries = &common_declarations[file.fullpath]
                            }
                            
                            assert(len(declaration.values) == 1)
                            value := declaration.values[0]
                            assert(len(declaration.names) == 1)
                            name := declaration.names[0]
                            ident := name.derived_expr.(^ast.Ident)
                            
                            append(entries, Info {
                                name = ident.name,
                                location = declaration.pos,
                                // @note(viktor): type is not needed here
                            })
                        }
                    }
                }
                
            case ^ast.Import_Decl:
                if has_attribute(declaration.attributes[:], `common="file"`) {
                    assert(declaration_index == 0)
                    append_common_file(&common_files, &common_declarations, file)
                }
            }
        }
    }
    
    return true
}

append_common_file :: proc (common_files: ^map[string] ^ast.File, common_declarations: ^map[string] [dynamic] Info, file: ^ast.File) {
    _, entries := delete_key(common_declarations, file.fullpath)
    delete(entries)
    common_files[file.fullpath] = file
}

////////////////////////////////////////////////

generate_commons :: proc (using mp: ^Metaprogram, path: string) -> (result: bool) {
    context.user_ptr = mp
    
    remove_if_exists(path)
    platform_file, err2 := os.open(path, mode = os.O_CREATE)
    defer os.close(platform_file)
    if err2 != nil do return false
    
    fmt.fprintf(platform_file, GeneratedHeader, "main")
    fmt.fprint(platform_file, `import "./game"`)
    fmt.fprint(platform_file, "\n\n")
    
    fmt.fprint(platform_file, "////////////////////////////////////////////////\n")
    fmt.fprintf(platform_file, "// all lose commons @generated by %s \n\n", #location())
    index: int
    for file_name, infos in common_declarations {
        if index != 0 do fmt.fprint(platform_file, "\n")
        defer index += 1
        
        for info in infos {
            fmt.fprintf(platform_file, "%v :: game.%v // @generated\n", info.name, info.name,)
        }
    }
    
    for path, file in common_files {
        fmt.fprint(platform_file, "\n////////////////////////////////////////////////\n")
        fmt.fprintf(platform_file, "// All commons exported from %s @generated by %s\n\n", path, #location())
        
        declarations: for declaration, index in file.decls {
            // @copypasta from is_common
            #partial switch declaration in declaration.derived_stmt {
                case ^ast.Value_Decl:
                if !declaration.is_mutable {
                    if len(declaration.values) > 0 {
                        assert(len(declaration.values) == 1)
                        value := declaration.values[0]
                        if has_attribute(declaration.attributes[:], "private", `private="file"`) {
                            continue declarations
                        }
                        
                        assert(len(declaration.names) == 1)
                        name := declaration.names[0]
                        ident := name.derived_expr.(^ast.Ident)
                        
                        if ident.name != "_" {
                            location := declaration.pos
                            fmt.fprintf(platform_file, "%v :: game.%v // @generated\n", ident.name, ident.name)
                        }
                    }
                }
            }
        }
    }
    
    fmt.printfln("INFO: generated commons")
    
    return true
}

generate_game_api :: proc(using mp: ^Metaprogram, output_file: string) -> (result: bool) {
    remove_if_exists(output_file)
    out, err := os.open(output_file, os.O_CREATE)
    defer os.close(out)
    if err != nil do return
    fmt.fprintfln(out, GeneratedHeader, "main")
    
    no_stubs: map[string]b32
    no_stubs["output_sound_samples"] = true
    no_stubs["update_and_render"] = true
    no_stubs["debug_frame_end"] = true
    
    
    longest_name: string
    for it in exports {
        if len(it.name) > len(longest_name) {
            longest_name = it.name
        }
    }
    width := len(longest_name)
    
    fmt.fprint(out, "import win \"core:sys/windows\"\n\n")
    
    // ugh...
    name_format := fmt.tprint("%-", width, "s", sep="")
    
    fmt.fprintf(out, "game_stubs :: GameApi {{ // @generated by %s\n", #location())
    for it in exports {
        if it.name in no_stubs do continue
        fmt.fprintf(out, "    ")
        fmt.fprintf(out, name_format, it.name)
        fmt.fprintf(out, " = %s {{ return }},\n", it.type)
    }
    fmt.fprint(out, "}\n\n")

    fmt.fprintf(out, "GameApi :: struct {{ // @generated by %s\n", #location())
    for it in exports {
        fmt.fprintf(out, "    ")
        fmt.fprintf(out, name_format, it.name)
        fmt.fprintf(out, " : %s,\n", it.type)
    }
    fmt.fprint(out, "}\n\n")
    
    fmt.fprintf(out, "load_game_api :: proc (game_lib: win.HMODULE) {{ // @generated by %s\n", #location())
    for it in exports {
        fmt.fprintf(out, "    game.")
        fmt.fprintf(out, name_format, it.name)
        fmt.fprintf(out, " = auto_cast win.GetProcAddress(game_lib, \"%s\")\n", it.name)
    }
    fmt.fprint(out, "}\n")
    
    fmt.printfln("INFO: generated game api")
    return true
}

generate_platform_api :: proc (apis: map[string] [dynamic] Info, platform_path, game_path: string) -> (result: bool) {
    remove_if_exists(game_path)
    game_file, err := os.open(game_path, mode = os.O_CREATE)
    defer os.close(game_file)
    if err != nil do return
    
    // @note(viktor): these members need to be in a defined and stable order, so that hotreloads do not mix up the procs.
    File :: struct { file_name: string, infos: [dynamic] Info }
    files: [dynamic] File
    for file_name, infos in apis {
        append(&files, File { file_name, infos })
        slice.sort_by(infos[:], proc(a, b: Info) -> bool { return strings.compare(a.name, b.name) <= 0 })
    }
    
    slice.sort_by(files[:], proc(a, b: File) -> bool { return strings.compare(a.file_name, b.file_name) <= 0 })
    
    ////////////////////////////////////////////////
    
    fmt.fprintf(game_file, GeneratedHeader, "game")
    
    fmt.fprintf(game_file, "@(common) Platform: Platform_Api // @generated by %s\n\n", #location())
    
    fmt.fprintf(game_file, "@(common) Platform_Api :: struct {{ // @generated by %s\n", #location())
        
    for file, index in files {
        if index != 0 do fmt.fprint(game_file, "    \n")
        
        for info in file.infos {
            fmt.fprintf(game_file, "    // @generated exported from %s(%d:%d)\n", info.location.file, info.location.line, info.location.column)
            
            fmt.fprintf(game_file, "    %v: %v,\n", info.name, info.type)
        }
    }
    fmt.fprint(game_file, "}\n")
    
    ////////////////////////////////////////////////
    
    remove_if_exists(platform_path)
    platform_file, err2 := os.open(platform_path, mode = os.O_CREATE)
    defer os.close(platform_file)
    if err2 != nil do return
    
    fmt.fprintf(platform_file, GeneratedHeader, "main")
    fmt.fprintf(platform_file, "Platform := Platform_Api {{ // @generated by %s\n", #location())
    // @note(viktor): We need to cast here, as we cannot expose some type to the game, but those are passed by pointer so the actual definition and size doesn't matter and we can safely cast.
    for file, index in files {
        if index != 0 do fmt.fprint(platform_file, "    \n")
        
        for info in file.infos {
            fmt.fprintf(platform_file, "    %v = auto_cast %v,\n", info.name, info.name)
        }
        
    }
    fmt.fprint(platform_file, "}\n")
    
    fmt.printfln("INFO: generated platform api")
    return true
}

////////////////////////////////////////////////

GeneratedHeader :: 
`#+vet !unused-procedures
package %v
///////////////////////////////////////////////
//                @important                 //
///////////////////////////////////////////////
//                                           //
//    THIS CODE IS GENERATED. DO NOT EDIT!   //
//                                           //
///////////////////////////////////////////////
 
`

has_attribute :: proc (attributes: [] ^ast.Attribute, targets: ..string) -> (result: bool) {
    loop: for attribute in attributes {
        for elem in attribute.elems {
            name := read_pos_or_fail(elem.pos, elem.end)
            for target in targets {
                if target == name {
                    result = true
                    break loop
                }
            }
        }
    }
    
    return result
}

collect_all_files :: proc(files: ^map[string] string, directory: string) {
    fi, _ := os2.read_directory_by_path(directory, -1, context.allocator)
    for f in fi {
        bytes, _ := os2.read_entire_file_from_path(f.fullpath, context.allocator)
        absolute_path, _ := os2.get_absolute_path(f.fullpath, context.allocator)
        files[absolute_path] = string(bytes)
    }
}

read_pos_or_fail :: proc(start, end: tokenizer.Pos) -> (result: string) {
    using mp := cast(^Metaprogram) context.user_ptr
    
    ok: bool
    result, ok = read_pos(start, end)
    assert(ok)
    return result
}

read_pos :: proc(start, end: tokenizer.Pos) -> (result: string, ok: bool) {
    using mp := cast(^Metaprogram) context.user_ptr
    
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
