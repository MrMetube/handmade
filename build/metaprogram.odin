#+vet unused shadowing cast unused-imports style unused-procedures unused-variables
package build

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"
import "core:terminal/ansi"
import "../code/game/shared" // Get the shared format string iterator. Ughh...

// @todo the parsing code still manually names all custom attributes, should this be split into multiple plugins that each define the attributes and then let the metaprogramm collect all named attributes into a plugins state, which then handles that stuff by itself.
Metaprogram :: struct {
    custom_attributes: [dynamic] string,
    
    files: map[string] string,
    
    nodes: map[string][dynamic] ^ast.Node,
    
    commons: map[string][dynamic] File,
    exports: map[string][dynamic] Info,
    
    apis:        [dynamic] File,
    api_opaques: [dynamic] Info,
    
    // @note(viktor): we assume that noone will make a local rename onto a name specified in another scope, scopes are ignored
    printlikes: map[string] Printlike,
    procedures: map[string] Return_Count,
    printlikes_failed: bool,
}

Info :: struct { 
    name: string, 
    type: string, 
    return_count: int,
    location: tokenizer.Pos,
}

Printlike :: struct {
    format_index: int, 
    args_index:   int,
}

Return_Count :: int

File :: struct {
    file_name: string,
    infos: [dynamic] Info,
}

Platform_Api_Tasks :: bit_set[enum { commons, global, opaques }]

metaprogram_init :: proc (mp: ^Metaprogram) {
    append(&mp.custom_attributes, "common")
    append(&mp.custom_attributes, "api")
    append(&mp.custom_attributes, "api_opaque")
    append(&mp.custom_attributes, "printlike")
    
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
        
        for name in builtins {
            mp.procedures[name] = 1
        }
    }
}

metaprogram_custom_attribute_flag :: proc (mp: ^Metaprogram) -> string {
    sb := strings.builder_make()
    fmt.sbprint(&sb, "-custom-attribute:")
    for attribute, index in mp.custom_attributes {
        if index != 0 do fmt.sbprint(&sb, ",")
        fmt.sbprint(&sb, attribute)
    }
    return strings.to_string(sb)
}

metaprogram_collect_files_and_parse_package :: proc (mp: ^Metaprogram, directory, package_name: string) -> (success: bool) {
    fi, err := os.read_directory_by_path(directory, 0, context.allocator)
    if err != nil {
        fmt.eprintfln("ERROR: The metaprogram failed to read the package %v", directory)
        return false
    }
    
    for f in fi {
        bytes, _ := os.read_entire_file_from_path(f.fullpath, context.allocator)
        absolute_path, _ := os.get_absolute_path(f.fullpath, context.allocator)
        mp.files[absolute_path] = cast(string) bytes
    }
    
    pack, ok := parser.parse_package_from_path(directory)
    if !ok {
        fmt.eprintfln("ERROR: The metaprogram failed to parse the package %v", directory)
        return false
    }
    
    nodes: [dynamic] ^ast.Node
    
    v := ast.Visitor{ visit = proc (visitor: ^ast.Visitor, node: ^ast.Node) -> (^ast.Visitor) {
        if node == nil do return nil
        nodes := cast(^[dynamic] ^ast.Node) visitor.data
        append(nodes, node)
        return visitor
    }, data = &nodes }
    
    ast.walk(&v, pack)
    mp.nodes[package_name] = nodes
    
    return true
}

////////////////////////////////////////////////

metaprogram_collect_plugin_data :: proc (mp: ^Metaprogram, package_name: string) -> (success: bool) {
    nodes, cok := mp.nodes[package_name]
    assert(cok)
    
    commons := map_insert(&mp.commons, package_name, [dynamic] File {})
    exports := map_insert(&mp.exports, package_name, [dynamic] Info {})
    
    file_commons: [dynamic] Info
    apis: [dynamic] Info
    files: for node in nodes {
        file, ok := node.derived.(^ast.File)
        if !ok do continue files
        
        for tag in file.tags {
            if tag.text == "#+private file" do continue files
        }
        
        clear(&file_commons)
        clear(&apis)
        
        is_common_file: bool
        global_value_declarations: [dynamic] ^ast.Value_Decl
        
        if len(file.decls) > 0 {
            #partial switch declaration in file.decls[0].derived_stmt {
            case ^ast.Value_Decl:
                if has_attribute(declaration, "common", `"file"`) {
                    is_common_file = true
                }
                
            case ^ast.Import_Decl:
                if has_attribute(declaration, "common", `"file"`) {
                    is_common_file = true
                }
            }
        }
        
        for declaration in file.decls {
            #partial switch declaration in declaration.derived_stmt {
            case ^ast.When_Stmt:
                // @note(viktor): We just assume that the block is true and get the bodys statements. If the else branch is missing we should always assume true and if there is an else branch, all relevant declarations need to be mirrored anyways.
                block := declaration.body.derived_stmt.(^ast.Block_Stmt)
                for statement in block.stmts {
                    if value_declaration, vok := statement.derived_stmt.(^ast.Value_Decl); vok {
                        append(&global_value_declarations, value_declaration)
                    }
                }
                
            case ^ast.Value_Decl: append(&global_value_declarations, declaration)
            }
        }
        
        for declaration in global_value_declarations {
            if declaration.is_mutable do continue
            attributes := make_attribute_map(declaration.attributes[:])
            if has_attribute(attributes, "private", `"file"`) do continue

            assert(len(declaration.names) == 1)
            ident := expect_ident(declaration.names[0])
            if ident.name == "_" do continue
            
            assert(len(declaration.values) == 1)
            value := declaration.values[0]
            
            info := Info {
                name     = ident.name,
                location = declaration.pos,
            }
            
            if "api" in attributes {
                procedure := expect_procedure(value)
                info.type = read_pos(mp, procedure.type.pos, procedure.type.end)
                append(&apis, info)
                continue
            }
            
            if "api_opaque" in attributes {
                append(&mp.api_opaques, info)
                continue
            }
            
            if "export" in attributes {
                assert(len(declaration.attributes) == 1)
                
                procedure := expect_procedure(value)
                info.type         = read_pos(mp, procedure.type.pos, procedure.type.end)
                info.return_count = procedure_return_count(procedure)
                append(exports, info)
                continue
            }
            
            if is_common_file || "common" in attributes {
                append(&file_commons, info)
                continue
            }
        }
        
        slice.sort_by(file_commons[:], sort_infos)
        slice.sort_by(apis[:],         sort_infos)
        
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
    slice.sort_by(mp.apis[:], sort_files)
    slice.sort_by(exports[:], sort_infos)
    
    renames: map[^ast.Ident] ^ast.Ident
    
    for node in nodes {
        declaration := node.derived.(^ast.Value_Decl) or_continue
        
        for element in soa_zip(value = declaration.values, name = declaration.names) {
            // @todo(viktor): lets assume that noone is using non-constant format procs
            value := element.value
            ident := expect_ident(element.name)
            
            #partial switch expression in value.derived_expr {
            case ^ast.Ident:
                renames[ident] = expression
                
            case ^ast.Proc_Lit:
                procedure := expression
                
                mp.procedures[ident.name] = procedure_return_count(procedure)
                
                if has_attribute(declaration, "printlike") {
                    printlike: Printlike
                    
                    found: bool
                    params: for param, param_index in procedure.type.params.list {
                        for name in param.names {
                            param_name := expect_ident(name).name
                            
                            #partial switch type in param.type.derived_expr {
                            case ^ast.Ident:
                                if type.name == "string" && param_name == "format" {
                                    printlike.format_index = param_index
                                }
                                
                            case ^ast.Ellipsis:
                                type_name := expect_ident(type.expr).name
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

check_printlikes :: proc (mp: ^Metaprogram, package_name: string) -> (success: bool) {
    nodes, cok := mp.nodes[package_name]
    if !cok do return false
    
    for node in nodes {
        if call, ok := node.derived.(^ast.Call_Expr); ok {
            check_printlike_call(mp, call)
        }
    }
    
    return !mp.printlikes_failed
}

////////////////////////////////////////////////

open_generated_file_and_write_header :: proc (path: string, package_name: string, loc := #caller_location) -> (^os.File, bool) {
    remove_if_exists(path)
    file, err2 := os.open(path, {.Create})
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

generate_commons :: proc (mp: ^Metaprogram, output_path, output_package: string, source_package, source_path_from_output_path: string) -> bool {
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
        generated_fprintf(out, "// All commons exported from %s", file.file_name)
        fmt.fprint(out, "\n")
        
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

generate_game_and_render_api :: proc (mp: ^Metaprogram, output_file, game_package, render_package, destination: string) -> bool {
    game_no_stubs: map[string] bool
    game_no_stubs["update_and_render"]    = true
    game_no_stubs["output_sound_samples"] = true
    game_no_stubs["debug_frame_end"]      = true
    
    game_required: map[string] bool
    game_required["output_sound_samples"] = true
    game_required["update_and_render"]    = true
    
    render_required: map[string] bool
    render_required["init"]             = true
    render_required["unload"]           = true
    render_required["hotreload"]        = true
    render_required["deinit"]           = true
    render_required["render"]           = true
    render_required["allocate_texture"] = true
    render_required["manage_textures"]  = true
    
    out, ok := open_generated_file_and_write_header(output_file, destination)
    if !ok {
        fmt.printf("ERROR: Could not generate api\n")
        return false
    }
    defer os.close(out)
    
    Source :: struct {
        name: string,
        no_stubs: map[string] bool,
        required: map[string] bool,
    }
    
    sources: [dynamic; 2] Source
    append(&sources, { game_package, game_no_stubs, game_required })
     
    if render_package != "" {
        append(&sources, { render_package, nil, render_required })
    }
    
    fmt.fprint(out, "import win \"core:sys/windows\"\n\n")
    
    for source in sources {
        type_name := strings.to_pascal_case(fmt.tprintf("%s_api", source.name), context.temp_allocator)
        
        exports, eok := mp.exports[source.name]
        assert(eok)
        
        width: int
        for it in exports {
            width = max(width, len(it.name))
        }
        
        generated_fprintf(out, "%s := %s_stubs", source.name, source.name)
        fmt.fprint(out, "\n")
        
        generated_fprintf(out, "%s_stubs :: %s {{", source.name, type_name)
        for it in exports {
            if it.name in source.no_stubs do continue
            if it.return_count > 0 {
                fmt.fprintf(out, "    %-*s = %s {{ return {{}} }},\n", width, it.name, it.type)
            } else {
                fmt.fprintf(out, "    %-*s = %s {{}},\n", width, it.name, it.type)
            }
        }
        fmt.fprint(out, "}\n\n")

        generated_fprintf(out, "%s :: struct {{", type_name)
        for it in exports {
            fmt.fprintf(out, "    %v:%*v %s,\n", space_after(it.name, width), it.type)
        }
        fmt.fprint(out, "}\n\n")
        
        generated_fprintf(out, "load_%s_api :: proc (lib: win.HMODULE) -> bool {{", source.name)
        for it in exports {
            fmt.fprintf(out, "    %s.%-*s = auto_cast win.GetProcAddress(lib, \"%s\")\n", source.name, width, it.name, it.name)
        }
        fmt.fprint(out, "    \n")
        
        for it in exports {
            if it.name in source.required { continue }
            fmt.fprintf(out, "    if %s.%-*s == nil {{ %s.%-*s = %s_stubs.%s }}\n", source.name, width, it.name, source.name, width, it.name, source.name, it.name)
        }
        fmt.fprint(out, "    \n")
        
        fmt.fprint(out, "    return ")
        first := true
        for it in exports {
            if it.name not_in source.required { continue }
            if !first do fmt.fprint(out, " &&\n           ")
            fmt.fprintf(out, "%s.%s != nil", source.name, it.name)
            first = false
        }
        fmt.fprint(out, "\n}\n")
        
        fmt.printfln("INFO: generated %v api for %v", source.name, destination)
    }
    
    return true
}

generate_platform_api :: proc (mp: ^Metaprogram, path, package_name: string, tasks: Platform_Api_Tasks) -> bool {
    if tasks != {} {
        out, ok := open_generated_file_and_write_header(path, package_name)
        if !ok do return false
        defer os.close(out)
        
        if .opaques in tasks {
            for info in mp.api_opaques {
                generated_fprintf(out, "%s :: struct {{}}", info.name)
            }
            fmt.fprint(out, "\n")
        }
        
        if .global in tasks {
            generated_fprintf(out, "Platform: Platform_Api")
            fmt.fprint(out, "\n")
        }
        
        // @cleanup @api how should the platform expose functions to the dlls?
        if .commons in tasks {
            fmt.fprintf(out, "@(common) ")
            generated_fprintf(out, "Platform_Api :: struct {{")
                
            for file, index in mp.apis {
                if index != 0 do fmt.fprint(out, "    \n")
                
                name_width: int
                type_width: int
                for info in file.infos {
                    name_width = max(name_width, len(info.name))
                    type_width = max(type_width, len(info.type))
                }
                
                for info in file.infos {
                    fmt.fprintf(out, "    // exported from %s(%d:%d)\n", info.location.file, info.location.line, info.location.column)
                    fmt.fprintf(out, "    %v:%*v %v,%*v\n", space_after(info.name, name_width), space_after(info.type, type_width))
                }
            }
            fmt.fprint(out, "}\n")
            fmt.fprint(out, "\n")
        }
        
        fmt.printfln("INFO: generated platform api for %v", package_name)
    }
    
    return true
}

generate_platform_api_bindings :: proc (mp: ^Metaprogram, path, package_name: string) -> bool {
    out, ok := open_generated_file_and_write_header(path, package_name)
    if !ok do return false
    defer os.close(out)
    
    generated_fprintf(out, "Platform := Platform_Api {{")
    // @note(viktor): We need to cast here, as we cannot expose some type to the game, but those are passed by pointer so the actual definition and size doesn't matter and we can safely cast.
    for file, index in mp.apis {
        if index != 0 do fmt.fprint(out, "\n")
        
        length := 0
        for info in file.infos {
            length = max(length, len(info.name))
        }
        for info in file.infos {
            fmt.fprintf(out, "    %-*v = auto_cast %v,\n", length, info.name, info.name)
        }
        
    }
    fmt.fprint(out, "}\n")
    
    fmt.printfln("INFO: generated platform api for %v", package_name)

    return true
}


generated_fprintf :: proc (file: ^os.File, format: string, args: ..any, loc := #caller_location) {
    fmt.fprintf(file, format, ..args)
    fmt.fprintf(file, " // @generated by %s\n", loc)
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

expect_ident :: proc (expression: ^ast.Expr) -> ^ast.Ident {
    ident, ok := expression.derived_expr.(^ast.Ident)
    assert(ok)
    return ident
}

expect_procedure :: proc (expression: ^ast.Expr) -> ^ast.Proc_Lit {
    procedure, ok := expression.derived_expr.(^ast.Proc_Lit)
    assert(ok)
    return procedure
}

procedure_return_count :: proc (procedure: ^ast.Proc_Lit) -> int {
    return procedure.type.results != nil ? len(procedure.type.results.list) : 0
}

check_printlike_call :: proc (mp: ^Metaprogram, call: ^ast.Call_Expr) {
    proc_ident: ^ast.Ident
    if ident, iok := call.expr.derived_expr.(^ast.Ident); iok {
        proc_ident = ident
    } else if selector, sok := call.expr.derived_expr.(^ast.Selector_Expr); sok {
        proc_ident = selector.field
    } else if union_contains(call.expr.derived_expr, ^ast.Basic_Directive) || union_contains(call.expr.derived_expr, ^ast.Paren_Expr) || union_contains(call.expr.derived_expr, ^ast.Asm_Template) {
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
                    
                    handled: bool
                    // @todo(viktor): some other expressions like ternary expressions could also yield more than one arg, but that would require a recursive approach
                    arg := arg
                    arg = ast.unparen_expr(arg)
                    #partial switch value in arg.derived_expr {
                    case ^ast.Call_Expr:
                        expr_name := expect_ident(value.expr).name
                        if procedure_return_count, proc_ok := mp.procedures[expr_name]; proc_ok {
                            actual += procedure_return_count
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

has_attribute :: proc { has_attribute_import, has_attribute_value, has_attribute_raw, has_attribute_map_value }
has_attribute_import :: proc (Import: ^ast.Import_Decl, target: string, target_value := "") -> bool {
    return has_attribute(Import.attributes[:], target, target_value)
}
has_attribute_value :: proc (value: ^ast.Value_Decl, target: string, target_value := "") -> bool {
    return has_attribute(value.attributes[:], target, target_value)
}
has_attribute_raw :: proc (attributes: [] ^ast.Attribute, target: string, target_value := "") -> bool {
    return has_attribute(make_attribute_map(attributes), target, target_value)
}
has_attribute_map_value :: proc (attributes: map[string] string, target: string, target_value := "") -> bool {
    value, ok := attributes[target]
    return ok && (target_value == "" || target_value == value)
}

make_attribute_map :: proc (attributes: [] ^ast.Attribute) -> map[string] string {
    result: map[string] string
    for attribute in attributes {
        for elem in attribute.elems {
            name: string
            value: string
            if field_value, fok := elem.derived_expr.(^ast.Field_Value); fok {
                name = expect_ident(field_value.field).name
                
                if lit, lok := field_value.value.derived_expr.(^ast.Basic_Lit); lok {
                    value = lit.tok.text
                }
            } else {
                name = expect_ident(elem).name
            }
            result[name] = value
        }
    }
    return result
}

read_pos :: proc (mp: ^Metaprogram, start, end: tokenizer.Pos) -> string {
    if start.file != end.file {
        fmt.eprintln("bad pos pair:", start, end)
        assert(false)
    }
    
    file, ok := mp.files[start.file]
    
    if !ok {
        fmt.eprintln("unknown file:", start.file)
        assert(false)
    }
    
    result := file[start.offset:end.offset]
    return result
}

sort_files :: proc (a, b: File) -> bool { return a.file_name < b.file_name }
sort_infos :: proc (a, b: Info) -> bool { return a.name < b.name }