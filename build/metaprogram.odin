#+vet unused shadowing cast unused-imports style unused-procedures unused-variables
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
    location: tokenizer.Pos,
}

Printlike :: struct {
    name:         string,
    format_index: int, 
    args_index:   int,
}

Procedure :: struct {
    name:         string,
    return_count: u32,
}

Metaprogram :: struct {
    files: map[string] string,
    
    commons: map[string] [dynamic] Info,
    exports: [dynamic] Info,
    
    apis: map[string] [dynamic] Info,
    
    printlikes: map[string] Printlike,
    procedures: map[string] Procedure,
    printlikes_failed: bool,
}

metaprogram_collect_data :: proc (using mp: ^Metaprogram, dir: string) -> (success: b32) {
    context.user_ptr = mp
    
    collect_all_files(&files, dir)
    
    pack, ok := parser.parse_package_from_path(dir)
    if !ok {
        fmt.printfln("ERROR: The metaprogram failed to parse the package %v", dir)
        return false
    }
    
    // @todo(viktor): Can we unify this simple loop and the tree walk below into a simple api for plugins?
    files: for _, file in pack.files {
        for tag in file.tags {
            if tag.text == "#+private file" do continue files
        }
        
        is_common_file := false
        for declaration, declaration_index in file.decls {
            #partial switch declaration in declaration.derived_stmt {
              case ^ast.When_Stmt:
                // @note(viktor): We just assume that the block is true and get the bodys statements. If the else branch is missing we should always assume true and if there is an else branch, all relevant declarations need to be mirrored anyways.
                declaration_ := declaration
                declaration_ = declaration
                block := declaration.body.derived_stmt.(^ast.Block_Stmt)
                for statement in block.stmts {
                    if value_declaration, vok := statement.derived_stmt.(^ast.Value_Decl); vok {
                        handle_global_value_declaration(mp, file, value_declaration, is_common_file)
                    }
                }
                
              case ^ast.Value_Decl:
                if has_attribute(declaration.attributes[:], "common", `"file"`) {
                    assert(!is_common_file)
                    assert(declaration_index == 0)
                    is_common_file = true
                }
                handle_global_value_declaration(mp, file, declaration, is_common_file)
                
              case ^ast.Import_Decl:
                if has_attribute(declaration.attributes[:], "common", `"file"`) {
                    assert(!is_common_file)
                    assert(declaration_index == 0)
                    is_common_file = true
                }
            }
        }
    }
    
    v := ast.Visitor{ visit = collect_printlikes_and_procedures, data = mp }
    ast.walk(&v, pack)
    
    return true
}

////////////////////////////////////////////////

collect_printlikes_and_procedures :: proc (visitor: ^ast.Visitor, node: ^ast.Node) -> (result: ^ast.Visitor) {
    if node == nil do return nil
    
    using mp := cast(^Metaprogram) visitor.data
    
    decl, ok := node.derived.(^ast.Value_Decl);
    if !ok do return visitor
    
    if decl.is_mutable do return nil
    
    assert(len(decl.values) == 1)
    value := decl.values[0]
    
    assert(len(decl.names) == 1)
    name := decl.names[0].derived_expr.(^ast.Ident).name
    
    #partial switch procedure in value.derived_expr {
      case: return nil
      
      case ^ast.Ident: // @note(viktor): renaming
        if procedure.name in procedures {
            procedures[name] = procedures[procedure.name]
            
            if procedure.name in printlikes {
                printlikes[name] = printlikes[procedure.name]
            }
        }
        
      case ^ast.Proc_Lit:
        attributes := decl.attributes[:]
        
        results := procedure.type.results
        if results != nil {
            procedures[name] = {
                name = name,
                return_count = cast(u32) len(results.list),
            }
        } else {
            procedures[name] = {
                name = name,
                return_count = 0,
            }
        }
        
        if has_attribute(attributes, "printlike") {
            printlike := Printlike { name = name }
            
            found: bool
            params: for param, index in procedure.type.params.list {
                for name in param.names {
                    param_name := name.derived_expr.(^ast.Ident).name
                    
                    #partial switch type in param.type.derived_expr {
                      case ^ast.Ident:
                        if type.name == "string" && param_name == "format" {
                            printlike.format_index = index
                        }
                        
                      case ^ast.Ellipsis:
                        type_name := type.expr.derived_expr.(^ast.Ident).name
                        if type_name == "any" && param_name == "args" {
                            printlike.args_index = index
                            found = true
                            
                            break params
                        }
                    }
                }
            }
            
            assert(found)
            printlikes[name] = printlike
        }
    }
    
    return result
}

handle_global_value_declaration :: proc (using mp: ^Metaprogram, file: ^ast.File, declaration: ^ast.Value_Decl, is_common_file: bool) {
    if declaration.is_mutable do return
    if has_attribute(declaration.attributes[:], "private", `"file"`) do return

    assert(len(declaration.names) == 1)
    ident := declaration.names[0].derived_expr.(^ast.Ident)
    if ident.name == "_" do return
    
    assert(len(declaration.values) == 1)
    value := declaration.values[0]
    if has_attribute(declaration.attributes[:], "api") {
        file, file_ok := &apis[declaration.pos.file]
        if !file_ok {
            apis[declaration.pos.file] = {}
            file = &apis[declaration.pos.file]
        }
        
        procedure := value.derived_expr.(^ast.Proc_Lit)
        append(file, Info {
            name = ident.name,
            type = read_pos(mp, procedure.type.pos, procedure.type.end),
            location = declaration.pos,
        })
    }
    
    if has_attribute(declaration.attributes[:], "export") {
        assert(len(declaration.attributes) == 1)
        
        procedure := value.derived_expr.(^ast.Proc_Lit)
        append(&exports, Info {
            name = ident.name,
            type = read_pos(mp, procedure.type.pos, procedure.type.end),
            location = declaration.pos,
        })
    }
    
    if is_common_file || has_attribute(declaration.attributes[:], "common") {
        entries, entries_ok := &commons[file.fullpath]
        if !entries_ok {
            commons[file.fullpath] = {}
            entries = &commons[file.fullpath]
        }
        
        append(entries, Info {
            name = ident.name,
            location = declaration.pos,
            // @note(viktor): type is not needed here
        })
    }
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
    fmt.fprint(platform_file, "\n")
    
    for file, infos in commons {
        fmt.fprint(platform_file, "\n////////////////////////////////////////////////\n")
        fmt.fprintf(platform_file, "// All commons exported from %s @generated by %s\n\n", file, #location())
        
        for info in infos {
            fmt.fprintf(platform_file, "/* @generated */ %v :: game.%v\n", info.name, info.name,)
        }
    }
    
    fmt.printfln("INFO: generated commons")
    
    return true
}

generate_game_api :: proc (using mp: ^Metaprogram, output_file: string) -> (result: bool) {
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

generate_platform_api :: proc (using mp: ^Metaprogram, platform_path, game_path: string) -> (result: bool) {
    remove_if_exists(game_path)
    game_file, err := os.open(game_path, mode = os.O_CREATE)
    defer os.close(game_file)
    if err != nil do return
    
    // @note(viktor): these members need to be in a defined and stable order, so that hotreloads do not mix up the procs.
    File :: struct { file_name: string, infos: [dynamic] Info }
    api_files: [dynamic] File
    for file_name, infos in apis {
        append(&api_files, File { file_name, infos })
        slice.sort_by(infos[:], proc (a, b: Info) -> bool { return strings.compare(a.name, b.name) <= 0 })
    }
    
    slice.sort_by(api_files[:], proc (a, b: File) -> bool { return strings.compare(a.file_name, b.file_name) <= 0 })
    
    ////////////////////////////////////////////////
    
    fmt.fprintf(game_file, GeneratedHeader, "game")
    
    fmt.fprintf(game_file, "@(common) Platform: Platform_Api // @generated by %s\n\n", #location())
    
    fmt.fprintf(game_file, "@(common) Platform_Api :: struct {{ // @generated by %s\n", #location())
        
    for file, index in api_files {
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
    for file, index in api_files {
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

check_printlikes :: proc (using mp: ^Metaprogram, dir: string) -> (success: bool) {
    pkg, ok := parser.parse_package_from_path(dir)
    assert(ok)
    
    v := ast.Visitor{ visit = visit_and_check_printlikes, data = mp }
    ast.walk(&v, pkg)
    
    return !mp.printlikes_failed
}

visit_and_check_printlikes :: proc (visitor: ^ast.Visitor, node: ^ast.Node) -> (result: ^ast.Visitor) {
    if node == nil do return nil
    
    using mp := cast(^Metaprogram) visitor.data
    
    #partial switch call in node.derived {
      case ^ast.Call_Expr:
        call_text := read_pos(mp, call.pos, call.open)
        name := call_text
        index := strings.index_byte(name, '.')
        if index != -1 {
            name = name[index+1:]
        }
        
        printlike, ok := printlikes[name]
        if !ok do return visitor
        
        assert(printlike.format_index <= len(call.args))
        
        format_arg := call.args[printlike.format_index]
        // @todo(viktor): @incomplete handle the format being set by name
        if _, set_format_by_name := format_arg.derived_expr.(^ast.Field_Value); set_format_by_name do return visitor
        
        format := read_pos(mp, format_arg.pos, format_arg.end)
        format_string_ok, expected := get_expected_format_string_arg_count(format)
        
        the_actual_arg_count_is_unknown := false
        the_actual_arg_count_is_unknown_because: string
        
        actual: u32
        if format_string_ok {
            if printlike.args_index >= len(call.args) {
                // @note(viktor): no args where passed
                actual = 0
            } else {
                args := call.args[printlike.args_index]
                if _, set_args_by_name := args.derived_expr.(^ast.Field_Value); set_args_by_name {
                    the_actual_arg_count_is_unknown = true
                    the_actual_arg_count_is_unknown_because = "The args are assigned by name, therefore we cannot know where they were declared and check them there."
                    // @todo(viktor): if it is an array literal we can still check it
                } else {
                    outer: for arg in call.args[printlike.args_index:] {
                        if _, set_parameter_by_name := arg.derived_expr.(^ast.Field_Value); set_parameter_by_name do continue
                        
                        handled: b32
                        // @todo(viktor): some other expressions like ternary expressions could also yield more than one arg, but that would require a recursive approach
                        #partial switch value in arg.derived_expr {
                          case ^ast.Call_Expr:
                            expr_name := value.expr.derived_expr.(^ast.Ident).name
                            if procedure, proc_ok := procedures[expr_name]; proc_ok {
                                actual += procedure.return_count
                                handled = true
                            } else {
                                // @incomplete if the name is a proc group we dont know which of the procs is called, thanks bill..
                                the_actual_arg_count_is_unknown = true
                                the_actual_arg_count_is_unknown_because = "The args contain at least one call to a proc-groups."
                            }
                        }
                        
                        if !handled do actual += 1
                    }
                }
            }
        }
        
        if the_actual_arg_count_is_unknown {
            report_unchecked_printlike_call(mp, call, expected, the_actual_arg_count_is_unknown_because)
        } else {
            if expected != actual {
                report_printlike_error(mp, call, expected, actual)
            }
        }
    }
    
    return visitor
}

////////////////////////////////////////////////

report_printlike_error :: proc (using mp: ^Metaprogram, call: ^ast.Call_Expr, expected, actual: u32) {
    mp.printlikes_failed = true
    
    fmt.eprintf("%v%v:%v:%v: ", White, call.pos.file, call.pos.line, call.pos.column)
    fmt.eprintf("%vFormat Error: %v", Red, Reset)
    if expected == 0 {
        fmt.eprintf("There are no formating percent signs in the format string")
    } else if expected == 1 {
        fmt.eprintf("There is one formating percent sign in the format string")
    } else { 
        fmt.eprintf("There are %v formating percent signs in the format string", expected)
    }
    if actual == 0 {
        fmt.eprintf(", but you passed no arguments.\n")
    } else if actual == 1 {
        fmt.eprintf(", but you passed one argument.\n")
    } else { 
        fmt.eprintf(", but you passed %v arguments.\n", actual)
    }

    fmt.eprintf("\t%v", White)
    
    full_call := read_pos(mp, call.pos, call.end)
    report_highlight_percent_signs(full_call, expected)
}

report_unchecked_printlike_call :: proc (using mp: ^Metaprogram, call: ^ast.Call_Expr, expected: u32, excuse: string) {
    fmt.printf("%v%v:%v:%v: ", White, call.pos.file, call.pos.line, call.pos.column)
    fmt.printf("%vFormat Warning: %v", Yellow, Reset)
    fmt.printf("%v %v\n", "Unable to check the arguments count.", excuse)
    
    fmt.printf("\t%v", White)
    
    full_call := read_pos(mp, call.pos, call.end)
    report_highlight_percent_signs(full_call, expected)
}

report_highlight_percent_signs :: proc (full_call: string, expected: u32) {
    // @volatile :PrintlikeChecking the loop structure must be the same as in format_string 
    
    skip: b32
    for r, i in full_call {
        if skip {
            skip = false
            continue
        }
        if r == '%' {
            if i < len(full_call)-1 && full_call[i+1] == '%' {
                fmt.eprint("%%")
                skip = true
            } else {
                fmt.eprintf("%v%%%v", Blue, White)
            }
        } else {
            fmt.eprint(r)
        }
    }
    
    fmt.eprintfln("%v", Reset)
    
    if expected == 0 {
        fmt.eprintfln("\n")
    } else if expected == 1 {
        fmt.eprintfln("\tThe percent sign that consumes an argument is highlighted.\n")
    } else {
        fmt.eprintfln("\tThe percent signs that consume an argument are highlighted.\n")
    }
}

// @volatile :PrintlikeChecking the loop structure must be the same as in format_string 
get_expected_format_string_arg_count :: proc (format: string) -> (ok: bool, count: u32) {
    if format[0] == '"' || format[0] == '`' {
        ok = true
        
        for index: int; index < len(format); index += 1 {
            if format[index] == '%' {
                if index+1 < len(format) && format[index+1] == '%' {
                    index += 1
                } else {
                    count += 1
                }
            }
        }
    }
    
    return ok, count
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

White  :: ansi.CSI + ansi.FG_BRIGHT_WHITE  + ansi.SGR
Red    :: ansi.CSI + ansi.FG_BRIGHT_RED    + ansi.SGR
Yellow :: ansi.CSI + ansi.FG_BRIGHT_YELLOW + ansi.SGR
Blue   :: ansi.CSI + ansi.FG_BRIGHT_BLUE   + ansi.SGR
Green  :: ansi.CSI + ansi.FG_BRIGHT_GREEN  + ansi.SGR
Reset  :: ansi.CSI + ansi.FG_DEFAULT       + ansi.SGR

has_attribute :: proc (attributes: [] ^ast.Attribute, target: string, target_value := "") -> (result: bool) {
    loop: for attribute in attributes {
        for elem in attribute.elems {
            name: string
            value: string
            if field_value, fok := elem.derived_expr.(^ast.Field_Value); fok {
                name = field_value.field.derived_expr.(^ast.Ident).name
                
                if lit, lok := field_value.value.derived_expr.(^ast.Basic_Lit); lok {
                    value = lit.tok.text
                }
            } else {
                name = elem.derived_expr.(^ast.Ident).name
            }
            
            if target == name {
                if target_value == "" || target_value == value {
                    result = true
                }
                
                break loop
            }
        }
    }
    
    return result
}

collect_all_files :: proc (files: ^map[string] string, directory: string) {
    fi, _ := os2.read_directory_by_path(directory, -1, context.allocator)
    for f in fi {
        bytes, _ := os2.read_entire_file_from_path(f.fullpath, context.allocator)
        absolute_path, _ := os2.get_absolute_path(f.fullpath, context.allocator)
        files[absolute_path] = cast(string) bytes
    }
}

read_pos :: proc (using mp: ^Metaprogram, start, end: tokenizer.Pos) -> (result: string) {
    if start.file != end.file {
        fmt.println("bad pos pair:", start, end)
        assert(false)
    }
    
    file, ok := files[start.file]
    
    if !ok {
        fmt.println("unknown file:", start.file)
        assert(false)
    }
    
    result = file[start.offset:end.offset]
    return result
}