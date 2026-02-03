package shared

// @todo(viktor): This sucks ass!

Format_Iterator :: struct {
    format: string,
    index:  int,
}
Format_Iterator_Result_Kind :: enum {
    Text, Percent, Escaped,
}
Format_Iterator_Result :: struct {
    kind: Format_Iterator_Result_Kind,
    text: string,
}

make_format_iterator :: proc (format: string) -> Format_Iterator {
    result := Format_Iterator {
        format = format,
    }
    return result
}

iterate_format :: proc (iter: ^Format_Iterator) -> (value: Format_Iterator_Result, index: int, condition: bool) {
    if iter.index >= len(iter.format) do return {}, len(iter.format), false
    
    index = iter.index
    
    if iter.format[iter.index] == '%' {
        if iter.index+1 < len(iter.format) && iter.format[iter.index+1] == '%' {
            value.kind = .Escaped
            iter.index += 2
        } else {
            value.kind = .Percent
            iter.index += 1
        }
    } else {
        for iter.index < len(iter.format) && iter.format[iter.index] != '%'{
            iter.index += 1
        }
    }
    
    value.text = iter.format[index:iter.index]
    return value, index, true
}