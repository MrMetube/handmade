#+vet unused shadowing cast unused-imports style unused-procedures unused-variables
package build

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:os/os2"
import "core:slice"
import "core:terminal/ansi"
import "../code/game/shared" // Get the shared format string iterator. Ughh...

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
    return_count: int,
}

File :: struct {
    file_name: string,
    infos: [dynamic] Info,
}

Metaprogram :: struct {
    files: map[string] string,
    
    collections: map[string] Collector,
    
    commons: map[string][dynamic] File,
    exports: map[string][dynamic] Info,
    
    apis: [dynamic] File,
    
    // @note(viktor): we assume that noone will make a local rename onto a name specified in another scope, scopes are ignored
    printlikes: map[string] Printlike,
    procedures: map[string] Procedure,
    printlikes_failed: bool,
}

Collector :: struct {
    entries: [dynamic] Collector_Entry,
    stack:   [dynamic] int,
}

Collector_Entry :: struct {
    node: ^ast.Node,
    next: int,
}

metaprogram_collect_files_and_parse_package :: proc (mp: ^Metaprogram, directory, package_name: string) -> (success: bool) {
    fi, err := os2.read_directory_by_path(directory, -1, context.allocator)
    if err != nil {
        fmt.eprintfln("ERROR: The metaprogram failed to read the package %v", directory)
        return false
    }
    
    for f in fi {
        bytes, _ := os2.read_entire_file_from_path(f.fullpath, context.allocator)
        absolute_path, _ := os2.get_absolute_path(f.fullpath, context.allocator)
        mp.files[absolute_path] = cast(string) bytes
    }
    
    pack, ok := parser.parse_package_from_path(directory)
    if !ok {
        fmt.eprintfln("ERROR: The metaprogram failed to parse the package %v", directory)
        return false
    }
    
    collector: Collector
    
    v := ast.Visitor{ visit = proc (visitor: ^ast.Visitor, node: ^ast.Node) -> (^ast.Visitor) {
        s  := cast(^Collector) visitor.data
        if node != nil {
            idx := len(s.entries)
            append(&s.entries, Collector_Entry{ node = node, next = -1 })
            append(&s.stack, idx)
            return visitor
        } else {
            // nil node means we are done with the children of the last node
            idx := pop(&s.stack)
            s.entries[idx].next = len(s.entries)
            return nil
        }
        
        return visitor
    }, data = &collector }
    
    ast.walk(&v, pack)
    mp.collections[package_name] = collector
    
    return true
}

////////////////////////////////////////////////

metaprogram_collect_plugin_data :: proc (mp: ^Metaprogram, path_from_build, package_name: string) -> (success: b32) {
    collector, cok := mp.collections[package_name]
    assert(cok)
    
    commons := map_insert(&mp.commons, package_name, [dynamic] File {})
    exports := map_insert(&mp.exports, package_name, [dynamic] Info {})
    
    file_commons: [dynamic] Info
    apis: [dynamic] Info
    files: for index: int; index < len(collector.entries); {
        e := collector.entries[index]
        skip_children: bool
        defer index = skip_children ? e.next : index+1
        
        file, ok := e.node.derived.(^ast.File)
        if !ok do continue files
        
        for tag in file.tags {
            if tag.text == "#+private file" do continue files
        }
        
        clear(&file_commons)
        clear(&apis)
        
        is_common_file := false
        for declaration, declaration_index in file.decls {
            
            #partial switch declaration in declaration.derived_stmt {
              case ^ast.When_Stmt:
                // @note(viktor): We just assume that the block is true and get the bodys statements. If the else branch is missing we should always assume true and if there is an else branch, all relevant declarations need to be mirrored anyways.
                block := declaration.body.derived_stmt.(^ast.Block_Stmt)
                for statement in block.stmts {
                    if value_declaration, vok := statement.derived_stmt.(^ast.Value_Decl); vok {
                        handle_global_value_declaration(mp, file, value_declaration, is_common_file, &file_commons, &apis, exports)
                    }
                }
                
              case ^ast.Value_Decl:
                if has_attribute(declaration, "common", `"file"`) {
                    assert(!is_common_file)
                    assert(declaration_index == 0)
                    is_common_file = true
                }
                handle_global_value_declaration(mp, file, declaration, is_common_file, &file_commons, &apis, exports)
                
              case ^ast.Import_Decl:
                if has_attribute(declaration, "common", `"file"`) {
                    assert(!is_common_file)
                    assert(declaration_index == 0)
                    is_common_file = true
                }
            }
        }
        
        if len(file_commons) > 0 {
            append(commons, File { file_name = file.fullpath, infos = file_commons})
            file_commons = make([dynamic] Info)
        }
        if len(apis) > 0 {
            append(&mp.apis, File { file_name = file.fullpath, infos = apis})
            apis = make([dynamic] Info)
        }
    }
    
    
    
    slice.sort_by(commons[:], sort_files)
    slice.sort_by(mp.apis[:],    sort_files)
    
    for file in commons do slice.sort_by(file.infos[:], sort_infos)
    for file in mp.apis do slice.sort_by(file.infos[:], sort_infos)
    
    slice.sort_by(exports[:], sort_infos)
    
    
    
    {
        // @note(viktor): assuming all builtins can only return one value
        // Taken from <path to ols>\builtin\builtin.odin
        builtins := [?] string {
            "len", "cap",
            "size_of", "align_of",
            "type_of", "type_info_of", "typeid_of",
            "offset_of_selector", "offset_of_member", "offset_of", "offset_of_by_string",
            "swizzle",
            "complex", "quaternion", "real", "imag", "jmag", "kmag", "conj",
            "min", "max", "abs", "clamp",
            "raw_data",
        }
        
        for b in builtins {
            mp.procedures[b] = { name = b, return_count = 1 }
        }
    }
    
    renames: map[^ast.Ident] ^ast.Ident
    
    for index: int; index < len(collector.entries); {
        e := collector.entries[index]
        skip_children: bool
        defer index = skip_children ? e.next : index+1
        
        declaration, ok := e.node.derived.(^ast.Value_Decl)
        if !ok do continue
        
        for element in soa_zip(value = declaration.values, name = declaration.names) {
            // @todo(viktor): lets assume that noone is using non-constant format procs
            value := element.value
            ident := element.name.derived_expr.(^ast.Ident)
            
            #partial switch expression in value.derived_expr {
            case ^ast.Ident:
                renames[ident] = expression
                
            case ^ast.Proc_Lit:
                procedure := expression
                
                mp.procedures[ident.name] = {
                    name = ident.name,
                    return_count = procedure.type.results != nil ? len(procedure.type.results.list) : 0,
                }
                
                if has_attribute(declaration, "printlike") {
                    printlike := Printlike { name = ident.name }
                    
                    found: bool
                    params: for param, param_index in procedure.type.params.list {
                        for name in param.names {
                            param_name := name.derived_expr.(^ast.Ident).name
                            
                            #partial switch type in param.type.derived_expr {
                            case ^ast.Ident:
                                if type.name == "string" && param_name == "format" {
                                    printlike.format_index = param_index
                                }
                                
                            case ^ast.Ellipsis:
                                type_name := type.expr.derived_expr.(^ast.Ident).name
                                if type_name == "any" && param_name == "args" {
                                    printlike.args_index = param_index
                                    found = true
                                    
                                    break params
                                }
                            }
                        }
                    }
                    
                    assert(found)
                    mp.printlikes[ident.name] = printlike
                }
            }
            // @todo(viktor): how can we know the return value count for overloaded identifiers? do we need to check the types?
        }
    }
    
    for ident, value in renames {
        if value.name in mp.printlikes {
            mp.printlikes[ident.name] = mp.printlikes[value.name]
        }
    }
    
    return true
}

////////////////////////////////////////////////

handle_global_value_declaration :: proc (mp: ^Metaprogram, file: ^ast.File, declaration: ^ast.Value_Decl, is_common_file: bool, commons, apis, exports: ^[dynamic] Info) {
    if declaration.is_mutable do return
    if has_attribute(declaration, "private", `"file"`) do return

    assert(len(declaration.names) == 1)
    ident := declaration.names[0].derived_expr.(^ast.Ident)
    if ident.name == "_" do return
    
    assert(len(declaration.values) == 1)
    value := declaration.values[0]
    if has_attribute(declaration, "api") {
        procedure := value.derived_expr.(^ast.Proc_Lit)
        append(apis, Info {
            name = ident.name,
            type = read_pos(mp, procedure.type.pos, procedure.type.end),
            location = declaration.pos,
        })
    }
    
    if has_attribute(declaration, "export") {
        assert(len(declaration.attributes) == 1)
        
        procedure := value.derived_expr.(^ast.Proc_Lit)
        append(exports, Info {
            name = ident.name,
            type = read_pos(mp, procedure.type.pos, procedure.type.end),
            location = declaration.pos,
        })
    }
    
    if is_common_file || has_attribute(declaration, "common") {
        append(commons, Info {
            name = ident.name,
            location = declaration.pos,
            // @note(viktor): type is not needed here
        })
    }
}

check_printlikes :: proc (mp: ^Metaprogram, package_name: string) -> (success: bool) {
    collector, cok := mp.collections[package_name]
    if !cok do return false
    
    for index: int; index < len(collector.entries); {
        skip_children: bool
        node := collector.entries[index]
        
        if call, ok := node.node.derived.(^ast.Call_Expr); ok {
            check_printlike_call(mp, call)
        }
        
        index = skip_children ? node.next : index+1
    }
    
    return !mp.printlikes_failed
}

////////////////////////////////////////////////

open_generated_file_and_write_header :: proc (path: string, package_name: string, loc := #caller_location) -> (os.Handle, bool) {
    remove_if_exists(path)
    file, err2 := os.open(path, mode = os.O_CREATE)
    if err2 != nil do return file, false
    
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
// @generated by %v

`

    fmt.fprintf(file, GeneratedHeader, package_name, loc)
    
    return file, true
}

////////////////////////////////////////////////

generate_commons :: proc (mp: ^Metaprogram, output_path, output_package: string, source_package, source_path_from_output_path: string) -> (result: bool) {
    out, ok := open_generated_file_and_write_header(output_path, output_package)
    if !ok {
        fmt.println("ERROR: Could not extract declarations marked with @common into %v", output_package)
        return false
    }
    defer os.close(out)
    
    fmt.fprintf(out, `import "%v" %v`, source_path_from_output_path, "\n")
    
    commons, cok := mp.commons[source_package]
    assert(cok)
    
    for file in commons {
        fmt.fprint(out, "\n////////////////////////////////////////////////\n")
        fmt.fprintf(out, "// All commons exported from %s @generated by %s\n\n", file.file_name, #location())
        
        width: int
        for info in file.infos {
            width = max(width, len(info.name))
        }
        
        for info in file.infos {
            fmt.fprintf(out, "/* @generated */ %-*v :: %v.%v\n", width, info.name, source_package, info.name,)
        }
    }
    
    fmt.printfln("INFO: generated %v commons for %v", source_package, output_package)
    
    return true
}

generate_game_api :: proc (mp: ^Metaprogram, output_file, exports_package, output_package: string) -> (result: bool) {
    exports, eok := mp.exports[exports_package]
    assert(eok)
    
    out, ok := open_generated_file_and_write_header(output_file, output_package)
    if !ok {
        fmt.println("ERROR: Could not generate game api")
        return false
    }
    defer os.close(out)
    
    no_stubs: map[string] bool
    no_stubs["output_sound_samples"] = true
    no_stubs["update_and_render"] = true
    no_stubs["debug_frame_end"] = true
    
    // @todo(viktor): this is terrible @cleanup
    ignore: map[string] bool
    if output_package == "render" {
        ignore["debug_set_event_recording"] = true
    }
    
    width: int
    for it in exports {
        width = max(width, len(it.name))
    }
    
    fmt.fprint(out, "import win \"core:sys/windows\"\n\n")
    
    fmt.fprintf(out, "game := game_stubs // @generated by %s\n\n", #location())
    
    fmt.fprintf(out, "game_stubs :: GameApi {{ // @generated by %s\n", #location())
    for it in exports {
        if it.name in no_stubs do continue
        if it.name in ignore do continue
        fmt.fprintf(out, "    %-*s = %s {{ return }},\n", width, it.name, it.type)
    }
    fmt.fprint(out, "}\n\n")

    fmt.fprintf(out, "GameApi :: struct {{ // @generated by %s\n", #location())
    for it in exports {
        if it.name in ignore do continue
        fmt.fprintf(out, "    %v:%*v %s,\n", space_after(it.name, width), it.type)
    }
    fmt.fprint(out, "}\n\n")
    
    fmt.fprintf(out, "load_game_api :: proc (lib: win.HMODULE) {{ // @generated by %s\n", #location())
    for it in exports {
        if it.name in ignore do continue
        fmt.fprintf(out, "    game.%-*s = auto_cast win.GetProcAddress(lib, \"%s\")\n", width, it.name, it.name)
    }
    fmt.fprint(out, "}\n")
    
    fmt.printfln("INFO: generated game api %v", output_package)
    return true
}

_ := generate_render_api
generate_render_api :: proc (mp: ^Metaprogram, output_file, exports_package, output_package: string) -> (result: bool) {
    exports, eok := mp.exports[exports_package]
    assert(eok)
    
    out, ok := open_generated_file_and_write_header(output_file, output_package)
    if !ok {
        fmt.println("ERROR: Could not generate render api")
        return false
    }
    defer os.close(out)
    
    no_stubs: map[string]b32
    // no_stubs["output_sound_samples"] = true
    
    width: int
    for it in exports {
        width = max(width, len(it.name))
    }
    
    fmt.fprint(out, "import win \"core:sys/windows\"\n\n")
    
    fmt.fprintf(out, "render := render_stubs // @generated by %s\n\n", #location())
    
    fmt.fprintf(out, "render_stubs :: RenderApi {{ // @generated by %s\n", #location())
    for it in exports {
        if it.name in no_stubs do continue
        fmt.fprintf(out, "    %-*s = %s {{ return }},\n", width, it.name, it.type)
    }
    fmt.fprint(out, "}\n\n")

    fmt.fprintf(out, "RenderApi :: struct {{ // @generated by %s\n", #location())
    for it in exports {
        fmt.fprintf(out, "    %v:%*v %s,\n", space_after(it.name, width), it.type)
    }
    fmt.fprint(out, "}\n\n")
    
    fmt.fprintf(out, "load_render_api :: proc (lib: win.HMODULE) {{ // @generated by %s\n", #location())
    for it in exports {
        fmt.fprintf(out, "    render.%-*s = auto_cast win.GetProcAddress(lib, \"%s\")\n", width, it.name, it.name)
    }
    fmt.fprint(out, "}\n")
    
    fmt.printfln("INFO: generated render api for %v", output_package)
    return true
}

generate_platform_api :: proc (mp: ^Metaprogram, platform_path, platform_package, output_path, output_package: string, common: bool) -> (result: bool) {
    out_pack, ok := open_generated_file_and_write_header(output_path, output_package)
    if !ok do return false
    defer os.close(out_pack)
    
    ////////////////////////////////////////////////
    fmt.fprintf(out_pack, "Platform: Platform_Api // @generated by %s\n\n", #location())
    // @cleanup @api how should the platform expose functions to the dlls?
    if common {
        fmt.fprintf(out_pack, "@(common) ")
        fmt.fprintf(out_pack, "Platform_Api :: struct {{ // @generated by %s\n", #location())
            
        for file, index in mp.apis {
            if index != 0 do fmt.fprint(out_pack, "    \n")
            
            name_width: int
            type_width: int
            for info in file.infos {
                name_width = max(name_width, len(info.name))
                type_width = max(type_width, len(info.type))
            }
            
            for info in file.infos {
                fmt.fprintf(out_pack, "    // exported from %s(%d:%d)\n", info.location.file, info.location.line, info.location.column)
                fmt.fprintf(out_pack, "    %v:%*v %v,%*v\n", space_after(info.name, name_width), space_after(info.type, type_width))
            }
        }
        fmt.fprint(out_pack, "}\n")
    }
    
    ////////////////////////////////////////////////
    
    out_main, pok := open_generated_file_and_write_header(platform_path, platform_package)
    if !pok do return false
    defer os.close(out_main)
    
    fmt.fprintf(out_main, "Platform := Platform_Api {{ // @generated by %s\n", #location())
    // @note(viktor): We need to cast here, as we cannot expose some type to the game, but those are passed by pointer so the actual definition and size doesn't matter and we can safely cast.
    for file, index in mp.apis {
        if index != 0 do fmt.fprint(out_main, "\n")
        
        length := 0
        for info in file.infos {
            length = max(length, len(info.name))
        }
        for info in file.infos {
            fmt.fprintf(out_main, "    %-*v = auto_cast %v,\n", length, info.name, info.name)
        }
        
    }
    fmt.fprint(out_main, "}\n")
    
    fmt.printfln("INFO: generated platform api for %v", output_package)
    return true
}

space_after :: proc (s: string, width: int) -> (string, int, string) {
    width_after := width - len(s)
    return s, width_after, ""
}

////////////////////////////////////////////////

union_contains :: proc (value: $U, $T: typeid) -> bool {
    _, ok := value.(T)
    return ok
}

check_printlike_call :: proc (mp: ^Metaprogram, call: ^ast.Call_Expr) {
    proc_ident: ^ast.Ident
    if ident, iok := call.expr.derived_expr.(^ast.Ident); iok {
        proc_ident = ident
    } else if selector, sok := call.expr.derived_expr.(^ast.Selector_Expr); sok {
        proc_ident = selector.field
    } else if union_contains(call.expr.derived_expr, ^ast.Basic_Directive) || union_contains(call.expr.derived_expr, ^ast.Paren_Expr) || union_contains(call.expr.derived_expr, ^ast.Inline_Asm_Expr) {
        return
    } else {
        fmt.println(call)
        unimplemented()
    }
    
    name := proc_ident.name
    printlike, ok := mp.printlikes[name]
    if !ok do return
    
    assert(printlike.format_index <= len(call.args))
    format_arg := call.args[printlike.format_index]
    
    format: string
    if format_field_value, set_format_by_name := format_arg.derived_expr.(^ast.Field_Value); set_format_by_name {
        format_value := ast.unparen_expr(format_field_value.value)
        if lit, lok := format_value.derived_expr.(^ast.Basic_Lit); lok {
            if lit.tok.kind == .String {
                format = lit.tok.text
            } else {
                // @incomplete not handling any other kind or nested expression
            }
        } else {
            // @incomplete Not handling non-literal asignments
        }
    } else {
        format = read_pos(mp, format_arg.pos, format_arg.end)
    }
    
    if format == "" do return
    
    format_string_ok, expected := get_expected_format_string_arg_count(format)
    
    the_actual_arg_count_is_unknown := false
    the_actual_arg_count_is_unknown_because: string
    
    actual: int
    if format_string_ok {
        if printlike.args_index >= len(call.args) {
            // @note(viktor): no args where passed
            actual = 0
        } else {
            args := call.args[printlike.args_index]
            if arg_field_value, set_args_by_name := args.derived_expr.(^ast.Field_Value); set_args_by_name {
                fmt.printfln("%v:%v:%v", args.pos.file, args.pos.line, args.pos.column)
                arg_value := ast.unparen_expr(arg_field_value.value)
                if !union_contains(arg_value.derived_expr, ^ast.Ident) {
                    // @todo(viktor): if it is an array literal we can still check it
                } else {
                    the_actual_arg_count_is_unknown = true
                    the_actual_arg_count_is_unknown_because = "Cannot check the value of the variable assigned to the args parameter."
                }
            } else {
                outer: for arg in call.args[printlike.args_index:] {
                    if union_contains(arg.derived_expr, ^ast.Field_Value) do continue
                    
                    handled: b32
                    // @todo(viktor): some other expressions like ternary expressions could also yield more than one arg, but that would require a recursive approach
                    arg := arg
                    arg = ast.unparen_expr(arg)
                    #partial switch value in arg.derived_expr {
                    case ^ast.Call_Expr:
                        expr_name := value.expr.derived_expr.(^ast.Ident).name
                        if procedure, proc_ok := mp.procedures[expr_name]; proc_ok {
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

////////////////////////////////////////////////

report_printlike_error :: proc (mp: ^Metaprogram, call: ^ast.Call_Expr, expected, actual: int) {
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

report_unchecked_printlike_call :: proc (mp: ^Metaprogram, call: ^ast.Call_Expr, expected: int, excuse: string) {
    fmt.eprintf("%v%v:%v:%v: ", White, call.pos.file, call.pos.line, call.pos.column)
    fmt.eprintf("%vFormat Warning: %v", Yellow, Reset)
    fmt.eprintf("%v %v\n", "Unable to check the arguments count.", excuse)
    
    fmt.eprintf("\t%v", White)
    
    full_call := read_pos(mp, call.pos, call.end)
    report_highlight_percent_signs(full_call, expected)
}

report_highlight_percent_signs :: proc (full_call: string, expected: int) {
    escaped: int
    
    iter := shared.make_format_iterator(full_call)
    for part in shared.iterate_format(&iter) {
        if part.kind == .Percent {
            fmt.eprintf("%v%v%v", Blue, part.text, White)
        } else if part.kind == .Escaped {
            fmt.eprintf("%v%v%v", Yellow, part.text, White)
            escaped += 1
        } else {
            fmt.eprintf("%v", part.text)
        }
    }
    
    fmt.eprintfln("%v", Reset)
    
    if expected > 0 do fmt.eprintf("\t%v%v%v indicates a formatting percent sign.\n", Blue, "%",  Reset)
    if escaped  > 0 do fmt.eprintf("\t%v%v%v indicates an escaped percent sign.\n", Yellow, "%%", Reset)
    
    fmt.eprintf("\n")
}

get_expected_format_string_arg_count :: proc (format: string) -> (ok: bool, count: int) {
    if format[0] == '"' || format[0] == '`' {
        ok = true
        
        iter := shared.make_format_iterator(format)
        for element in shared.iterate_format(&iter) {
            if element.kind == .Percent {
                count += 1
            }
        }
    }
    
    return ok, count
}

////////////////////////////////////////////////

White  :: ansi.CSI + ansi.FG_BRIGHT_WHITE  + ansi.SGR
Red    :: ansi.CSI + ansi.FG_BRIGHT_RED    + ansi.SGR
Yellow :: ansi.CSI + ansi.FG_BRIGHT_YELLOW + ansi.SGR
Blue   :: ansi.CSI + ansi.FG_BRIGHT_BLUE   + ansi.SGR
Green  :: ansi.CSI + ansi.FG_BRIGHT_GREEN  + ansi.SGR
Reset  :: ansi.CSI + ansi.FG_DEFAULT       + ansi.SGR

has_attribute :: proc { has_attribute_import, has_attribute_value, has_attribute_raw }
has_attribute_import :: proc (Import: ^ast.Import_Decl, target: string, target_value := "") -> (result: bool) {
    return has_attribute(Import.attributes[:], target, target_value)
}
has_attribute_value :: proc (value: ^ast.Value_Decl, target: string, target_value := "") -> (result: bool) {
    return has_attribute(value.attributes[:], target, target_value)
}
has_attribute_raw :: proc (attributes: [] ^ast.Attribute, target: string, target_value := "") -> (result: bool) {
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

read_pos :: proc (mp: ^Metaprogram, start, end: tokenizer.Pos) -> (result: string) {
    if start.file != end.file {
        fmt.eprintln("bad pos pair:", start, end)
        assert(false)
    }
    
    file, ok := mp.files[start.file]
    
    if !ok {
        fmt.eprintln("unknown file:", start.file)
        assert(false)
    }
    
    result = file[start.offset:end.offset]
    return result
}

sort_files :: proc (a, b: File) -> bool { return a.file_name < b.file_name }
sort_infos :: proc (a, b: Info) -> bool { return a.name < b.name }