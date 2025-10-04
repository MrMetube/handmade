#+vet unused shadowing cast unused-imports style unused-procedures unused-variables
package build

import "core:fmt"
import "core:strings"
import "core:terminal/ansi"
import "core:odin/ast"
import "core:odin/parser"

Printlike :: struct {
    name:         string,
    format_index: int, 
    args_index:   int,
}

Procedure :: struct {
    name:         string,
    return_count: int,
}

check_printlikes :: proc (using mp: ^Metaprogram, dir: string) -> (succes: bool) {
    context.user_ptr = mp
    
    collect_all_files(&files, dir)
    
    code_package, ok := parser.parse_package_from_path(dir)
    assert(ok)
    
    return check_printlikes_by_package(code_package)
}

check_printlikes_by_package :: proc (pkg: ^ast.Package) -> (success: bool) {
    using mp := cast(^Metaprogram) context.user_ptr
    
    v := ast.Visitor{ visit = visit_and_collect_printlikes_and_procedures }
    ast.walk(&v, pkg)
    
    v = ast.Visitor{ visit = visit_and_check_printlikes }
    ast.walk(&v, pkg)
    
    return !mp.printlikes_failed
}

visit_and_collect_printlikes_and_procedures :: proc (visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
    if node == nil do return visitor
    
    using mp := cast(^Metaprogram) context.user_ptr
    
    #partial switch decl in node.derived {
      case ^ast.Value_Decl:
        attributes := decl.attributes[:]
        pos := decl.pos
        end := decl.end
        
        
        name, name_and_body: string
        {
            name_and_body = read_pos_or_fail(pos, end)
            eon := strings.index(name_and_body, "::")
            if eon == -1 do eon = len(name_and_body)-1
            name = name_and_body[:eon]
            name = strings.trim_space(name)
        }
        
        if len(decl.values) > 0 {
            value := decl.values[0]
            #partial switch procedure in value.derived_expr {
              case ^ast.Proc_Lit:
                results := procedure.type.results
                if results != nil {
                    p := Procedure {
                        name = name,
                        return_count = len(results.list),
                    }
                    procedures[p.name] = p
                }
                
                if has_attribute(attributes, "printlike") {
                    printlike := Printlike { name = name }
                    
                    found: b32
                    for param, index in procedure.type.params.list {
                        if len(param.names) < 1 do continue // when would this not apply
                        param_name := read_pos_or_fail(param.names[0].pos, param.names[0].end)
                        
                        if !found {
                            type := read_pos_or_fail(param.type.pos, param.type.end)
                            
                            if type == "string" && param_name == "format" {
                                printlike.format_index = index
                            }
                            
                            if type == "any" && param_name == "args" {
                                printlike.args_index = index
                                found = true
                                break
                            }
                        }
                    }
                    
                    text := read_pos_or_fail(decl.pos, decl.end)
                    text = text
                    printlikes[name] = printlike
                }
            }
        }
    }
    
    return visitor
}

visit_and_check_printlikes :: proc (visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
    using mp := cast(^Metaprogram) context.user_ptr
    
    if node == nil do return visitor
    
    #partial switch call in node.derived {
      case ^ast.Call_Expr:
        call_text := read_pos_or_fail(call.pos, call.open)
        name := call_text
        index := strings.index_byte(name, '.')
        if index != -1 {
            name = name[index+1:]
        }
        if printlike, ok := printlikes[name]; ok {
            if len(call.args) <= printlike.format_index do return visitor

            format_arg := call.args[printlike.format_index]
            if _, set_parameter_by_name := format_arg.derived_expr.(^ast.Field_Value); set_parameter_by_name do return visitor
        
            format := read_pos_or_fail(format_arg.pos, format_arg.end)
            indices: [dynamic]int
            format_string_ok := get_expected_format_string_arg_count(format, &indices)
            expected := len(indices)
            
            we_know_the_actual_arg_count := true
            
            actual: int
            if format_string_ok && printlike.args_index < len(call.args) {
                args := call.args[printlike.args_index]
                if _, set_parameter_by_name := args.derived_expr.(^ast.Field_Value); set_parameter_by_name do return visitor
                
                outer: for arg in call.args[printlike.args_index:] {
                    arg_text := read_pos_or_fail(arg.pos, arg.end)
                    
                    if _, set_parameter_by_name := arg.derived_expr.(^ast.Field_Value); set_parameter_by_name do continue
                    
                    handled: b32
                    #partial switch value in arg.derived_expr {
                      case ^ast.Call_Expr:
                        arg_text = arg_text
                        expr_name := read_pos_or_fail(value.expr.pos, value.expr.end)
                        if procedure, proc_ok := procedures[expr_name]; proc_ok {
                            actual += procedure.return_count
                            handled = true
                        } else {
                            // @incomplete if the name is a proc group we dont know which of the procs is called, thanks bill..
                            we_know_the_actual_arg_count = false
                        }
                    }
                    
                    if !handled do actual += 1
                }
            }
            
            if we_know_the_actual_arg_count {
                if expected != actual {
                    report_printlike_error(call, expected, actual)
                }
            } else {
                report_unchecked_printlike_call(call)
            }
        }
    }
    
    return visitor
}

////////////////////////////////////////////////

White  :: ansi.CSI + ansi.FG_BRIGHT_WHITE  + ansi.SGR
Red    :: ansi.CSI + ansi.FG_BRIGHT_RED    + ansi.SGR
Yellow :: ansi.CSI + ansi.FG_BRIGHT_YELLOW + ansi.SGR
Blue   :: ansi.CSI + ansi.FG_BRIGHT_BLUE   + ansi.SGR
Green  :: ansi.CSI + ansi.FG_BRIGHT_GREEN  + ansi.SGR
Reset  :: ansi.CSI + ansi.FG_DEFAULT       + ansi.SGR

report_printlike_error :: proc (call: ^ast.Call_Expr, expected, actual: int) {
    using mp := cast(^Metaprogram) context.user_ptr
    mp.printlikes_failed = true
    
    message := expected < actual ? "Too many arguments." : "Too few arguments."
    fmt.eprintf("%v%v:%v:%v: ", White, call.pos.file, call.pos.line, call.pos.column)
    fmt.eprintf("%vFormat Error: %v %v ", Red, Reset, message)
    if expected == 0 {
        fmt.eprintf("Expected no arguments, but got %v.\n", actual)
    } else if expected == 1 {
        fmt.eprintf("Expected 1 argument, but got %v.\n", actual)
    } else { 
        fmt.eprintf("Expected %v arguments, but got %v.\n", expected, actual)
    }

    full_call := read_pos_or_fail(call.pos, call.end)
    
    fmt.eprintf("\t%v", White)
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
    
    fmt.eprintfln("%v\n", Reset)
    if expected == 1 {
        fmt.eprintfln("\tThe percent sign that consumes an argument in the format string is highlighted.\n")
    } else if expected != 0 {
        fmt.eprintfln("\tThe percent signs that consume an argument in the format string are highlighted.\n")
    }
}

report_unchecked_printlike_call :: proc (call: ^ast.Call_Expr) {
    message := "Unable to check the arguments count, because we cannot check calls of proc-groups."
    fmt.printf("%v%v:%v:%v: ", White, call.pos.file, call.pos.line, call.pos.column)
    fmt.printfln("%vFormat Warning: %v %v", Yellow, Reset, message)
    
    full_call := read_pos_or_fail(call.pos, call.end)
    
    fmt.printf("\t%v", White)
    
    skip: b32
    for r, i in full_call {
        if skip {
            skip = false
            continue
        }
        if r == '%' {
            if i < len(full_call)-1 && full_call[i+1] == '%' {
                fmt.print("%%")
                skip = true
            } else {
                fmt.printf("%v%%%v", Blue, White)
            }
        } else {
            fmt.print(r)
        }
    }
    
    fmt.printfln("%v\n\tThe percent signs that consume an argument in the format string are highlighted.\n", Reset)
}

// :PrintlikeChecking @copypasta the loop structure must be the same as in format_string 
get_expected_format_string_arg_count :: proc (format: string, indices: ^[dynamic]int) -> (ok: bool) {
    if format[0] == '"' || format[0] == '`' {
        ok = true
        
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
    
    return ok
}