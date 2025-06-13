#+private
package build

import "core:fmt"
import "core:strings"
import "core:os"
import "core:log"
import "core:encoding/ansi"
import "core:os/os2"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"

Code :: struct {
    content: string, 
    location: tokenizer.Pos,
}

Printlike :: struct {
    name:         string,
    format_index: int, 
    args_index:   int,
    optional_arg_names: [dynamic]string,
}

Procedure :: struct {
    name: string,
    return_count: int,
}

ExtractContext :: struct {
    files:        map[string]string,
    imports:      map[string]Code,
    declarations: map[string]Code,
    common_files: map[string]b32,
    exports:      map[string]Code,
    
    printlikes:   map[string]Printlike,
    procedures:   map[string]Procedure,
}

_CommonTag     :: `common`
_CommonTagFile :: `common="file"`
ExportTag     :: `export`
Input         :: `D:\handmade\code\game`
Output        :: `D:\handmade\code`
GeneratedSuffix :: `\generated.odin`

extract_common_and_exports :: proc() -> (succes: b32) {
    using my_context: ExtractContext
    context.user_ptr = &my_context
    
    collect_all_files(Input)
    collect_all_files(Output)
    
    input_package, ok := parser.parse_package_from_path(Input)
    assert(ok)
    output_package, ok2 := parser.parse_package_from_path(Output)
    assert(ok2)
    
    
    // @todo(viktor): extract into separate thing
    if !check_printlikes(input_package) do return false
    if !check_printlikes(output_package) do return false
    
    output_package_name := "main" 
    extract_exports_and_generate_api(input_package, `D:\handmade\code`, `\exports-generated.odin`, output_package_name)
    // @note(viktor): prefer to do this last, so when debugging we dont keep detecting false positives if the code is not run to completion
    if !extract_common_game_declarations(input_package, `D:\handmade\code`, GeneratedSuffix, output_package_name) do return false
    return true
}

collect_all_files :: proc(directory: string) {
    using my := cast(^ExtractContext) context.user_ptr
    
    fi, _ := os2.read_directory_by_path(directory, -1, context.allocator)
    for f in fi {
        bytes, _ := os2.read_entire_file_from_path(f.fullpath, context.allocator)
        files[f.fullpath] = string(bytes)
    }
}

check_printlikes :: proc(pkg: ^ast.Package) -> (success: b32) {
    using my := cast(^ExtractContext) context.user_ptr
    
    v := ast.Visitor{ visit = visit_and_collect_printlikes_and_procedures }
    ast.walk(&v, pkg)
    
    v = ast.Visitor{ visit = visit_and_check_printlikes }
    ast.walk(&v, pkg)
    
    return true
}

Header :: 
`#+vet !unused-procedures
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
    no_stubs["debug_frame_end"] = true
    
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

extract_common_game_declarations :: proc(pkg: ^ast.Package, output_dir, output_file, output_package: string) -> (success: b32) {
    using my := cast(^ExtractContext) context.user_ptr
    
    v := ast.Visitor{ visit = visit_and_extract_commons }
    ast.walk(&v, pkg)
    
    time_of_exe, err := os.last_write_time_by_name(`.\debug.exe`)
    if err != nil do time_of_exe = 0
    
    for key, _ in common_files {
        path, _ := strings.replace(key, Input, output_dir, 1, context.temp_allocator)
        path, _ = strings.replace(path, ".odin", "-generated.odin", 1, context.temp_allocator)
        
        time_of_copypasta, err2 := os.last_write_time_by_name(path)
        was_modified := err2 != .Not_Exist && time_of_exe != 0 && time_of_copypasta > time_of_exe
        // @todo(viktor): Collect all errors and show and abort afterwards
        if was_modified {
            log.errorf(`
Error: A generated file was modifed:
  Generated: '%s'
  Original:  '%s'
  Migrate your changes or delete the generated file to proceed.`, path, key)
            return false
        }
    }
    
    for key, _ in common_files {
        path, _ := strings.replace(key, Input, output_dir, 1, context.temp_allocator)
        path, _ = strings.replace(path, ".odin", "-generated.odin", 1, context.temp_allocator)
        
        header := fmt.tprintf(Header, output_package)
        
        data := files[key]
        corrected, _ := strings.replace(data, "package game", header, -1, context.temp_allocator)
        corrected, _ = strings.replace(corrected, _CommonTagFile, "", -1, context.temp_allocator)
        os.write_entire_file(path, transmute([]u8) corrected)
    }
    
    output := fmt.tprint(output_dir, output_file, sep="")
    if os.exists(output) do os.remove(output)
    out, _ := os.open(output, os.O_CREATE)
    defer os.close(out)
    fmt.fprintfln(out, Header, output_package)
    
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
    
    return true
}

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
                att_name := read_pos_or_fail(expr.pos, expr.end)
                if strings.equal_fold(att_name, ExportTag) {
                    is_export = true
                    declaration = read_pos_or_fail(pos, end)
                    
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
                } else {
                    append(&other_attributes, fmt.tprint(att_name))
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

visit_and_collect_printlikes_and_procedures :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
    using my := cast(^ExtractContext) context.user_ptr
    
    if node == nil do return visitor
    
    attribute_names: [dynamic]string
    
    #partial switch decl in node.derived {
      case ^ast.Value_Decl:
        attributes := decl.attributes[:]
        pos := decl.pos
        end := decl.end
        
        name, name_and_body, attribute := collect_declarations_with_attribute(&attribute_names, "printlike", attributes, pos, end)
        if len(decl.values) > 0 {
            value := decl.values[0]
            procedure, ok := value.derived_expr.(^ast.Proc_Lit)
            if ok {
                results := procedure.type.results
                if results != nil {
                    p := Procedure {
                        name = name,
                        return_count = len(results.list)
                    }
                    procedures[p.name] = p
                }
            }
            
            if attribute != nil {
                printlike := Printlike { name = name }
                
                found: b32
                for param, index in procedure.type.params.list {
                    if len(param.names) < 1 do continue // when would this not apply
                    name := read_pos_or_fail(param.names[0].pos, param.names[0].end)
                    
                    if !found {
                        type := read_pos_or_fail(param.type.pos, param.type.end)
                        
                        if type == "string" && name == "format" {
                            printlike.format_index = index
                        }
                        
                        if type == "any" && name == "args" {
                            printlike.args_index = index
                            found = true
                        }
                    } else {
                        append(&printlike.optional_arg_names, name)
                    }
                }
                
                text := read_pos_or_fail(decl.pos, decl.end)
                text = text
                printlikes[name] = printlike
            }
        }
    }
    
    return visitor
}

visit_and_check_printlikes :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
    using my := cast(^ExtractContext) context.user_ptr
    
    if node == nil do return visitor
    
    #partial switch call in node.derived {
      case ^ast.Call_Expr:
        if strings.contains(call.pos.file, GeneratedSuffix) {
            return visitor
        }
        
        text := read_pos_or_fail(call.pos, call.open)
        if printlike, ok := printlikes[text]; ok {
            format_string_index := -1
            
            if len(call.args) <= printlike.format_index do return visitor
            if len(call.args) <= printlike.args_index   do return visitor
            
            format_arg := call.args[printlike.format_index]
            if _, set_parameter_by_name := format_arg.derived_expr.(^ast.Field_Value); set_parameter_by_name do return visitor
            
            format := read_pos_or_fail(format_arg.pos, format_arg.end)
            indices: [dynamic]int
            get_expected_format_string_arg_count(format, &indices)
            expected := len(indices)
            
            args := call.args[printlike.args_index]
            if _, set_parameter_by_name := args.derived_expr.(^ast.Field_Value); set_parameter_by_name do return visitor
            
            actual: int
            outer: for arg, index in call.args[printlike.args_index:] {
                arg_text := read_pos_or_fail(arg.pos, arg.end)
                
                if _, set_parameter_by_name := arg.derived_expr.(^ast.Field_Value); set_parameter_by_name do continue
                
                #partial switch value in arg.derived_expr {
                  case ^ast.Call_Expr:
                    arg_text = arg_text
                    name := read_pos_or_fail(value.expr.pos, value.expr.end)
                    if procedure, ok := procedures[name]; ok {
                        actual += procedure.return_count - 1
                    }
                  case: 
                }
                actual += 1
            }
            
            if expected != actual {
                White :: ansi.CSI + ansi.FG_BRIGHT_WHITE + ansi.SGR
                Red   :: ansi.CSI + ansi.FG_BRIGHT_RED + ansi.SGR
                Green :: ansi.CSI + ansi.FG_BRIGHT_GREEN + ansi.SGR
                Reset :: ansi.CSI + ansi.FG_DEFAULT + ansi.SGR
                message := expected < actual ? "Too many arguments." : "Too few arguments."
                fmt.printf("%v%v:%v:%v: ", White, call.pos.file, call.pos.line, call.pos.column)
                fmt.printf("%Format Error: %v %v ", Red, Reset, message, )
                fmt.printf("Expected %v arguments, but got %v\n", expected, actual)
                call_text := read_pos_or_fail(call.pos, call.end)
                fmt.printfln("\t%v%v%v", White, call_text, Reset)
                fmt.printf("\t%v", Green)
                for _ in 0..<len(printlike.name)+1 do fmt.print(' ')
                cursor: int
                for index, it_index in indices {
                    for _ in 0..<index-cursor do fmt.print(' ')
                    fmt.print('^')
                    cursor += index-cursor+1
                }
                for _ in 0..<len(call_text)-len(printlike.name)-cursor do fmt.print(' ')
                fmt.printfln("%v <- Here are the percent signs that consume an argument in the formatting.\n\n", Reset)
            }
        }
    }
    
    return visitor
}


// :PrintlikeChecking @Copypasta the loop structure must be the same as in format_string 
get_expected_format_string_arg_count :: proc(format: string, indices: ^[dynamic]int) {
    for index: int; index < len(format); index += 1 {
        if format[index] == '%' {
            if index+1 < len(format) && format[index+1] == '%' {
                index += 1
            } else {
                append(indices, index)
            }
        }
    }
}

visit_and_extract_commons :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
    using my := cast(^ExtractContext) context.user_ptr
    
    if node == nil do return visitor
    
    attribute_names: [dynamic]string
    
    #partial switch decl in node.derived {
      case ^ast.Value_Decl:
        attributes := decl.attributes[:]
        pos := decl.pos
        end := decl.end
        
        collect_common_files(attributes)
        name, name_and_body, attribute := collect_declarations_with_attribute(&attribute_names, _CommonTag, attributes, pos, end)
        
        if attribute != nil {
            builder: string
            
            atts := read_pos_or_fail(attribute.open, attribute.close)
            
            builder = fmt.tprint(builder, "@", sep = "")
            builder = fmt.tprint(builder, atts, sep = "")
            builder = fmt.tprint(builder, ")", sep = "")
            builder = fmt.tprint(builder, name_and_body, sep = "")
            
            declarations[name] = { content  = builder, location = pos }
        }
        
      case ^ast.Import_Decl:
        attributes := decl.attributes[:]
        pos := decl.pos
        end := decl.end
        
        collect_common_files(attributes)
        name, name_and_body, attribute := collect_declarations_with_attribute(&attribute_names, _CommonTag, attributes, pos, end)
        
        // @Copypasta
        if attribute != nil {
            atts := read_pos_or_fail(attribute.open, attribute.close)
            
            builder: string
            
            builder = fmt.tprint(builder, "@", sep = "")
            builder = fmt.tprint(builder, atts, sep = "")
            builder = fmt.tprint(builder, ")", sep = "")
            builder = fmt.tprint(builder, name_and_body, sep = "")
            
            imports[name] = { content  = builder, location = pos }
        }
    }
    
    return visitor
}

collect_common_files :: proc(attributes: []^ast.Attribute) {
    using my := cast(^ExtractContext) context.user_ptr
    
    for attribute in attributes[:] {
        if len(attribute.elems) == 0 do continue
        
        for expr in attribute.elems {
            att_name := read_pos_or_fail(expr.pos, expr.end)
            if strings.equal_fold(att_name, _CommonTagFile) {
                common_files[attribute.node.pos.file] = true
            }
        }
    }
}

collect_declarations_with_attribute :: proc(attribute_naems: ^[dynamic]string, target: string, attributes: []^ast.Attribute, pos, end: tokenizer.Pos) -> (name, name_and_body: string, result: ^ast.Attribute) {
    using my := cast(^ExtractContext) context.user_ptr
    
    name_and_body = read_pos_or_fail(pos, end)
    eon := strings.index(name_and_body, "::")
    if eon == -1 do eon = len(name_and_body)-1
    name = name_and_body[:eon]
    name = strings.trim_space(name)
    
    for &attribute in attributes {
        if len(attribute.elems) == 0 do continue
        
        is_marked_as_common: b32
        attribute_names: [dynamic]string
        
        for expr in attribute.elems {
            if att_name, ok := read_pos(expr.pos, expr.end); ok {
                if strings.equal_fold(att_name, target) {
                    result = attribute
                }
                append(&attribute_names, att_name)
            }
        }
    }
    
    return 
}


read_pos_or_fail :: proc(start, end: tokenizer.Pos) -> (result: string) {
    using my := cast(^ExtractContext) context.user_ptr
    ok: bool
    result, ok = read_pos(start, end)
    assert(ok)
    return result
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
