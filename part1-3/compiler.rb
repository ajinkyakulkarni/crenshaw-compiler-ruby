#!/usr/bin/env ruby

ADDOPS = %w(+ -)
MULOPS = %w(* /)

TAB = "\t"

HEADER = <<-ASM
.section __TEXT,__text
.global _main
_main:
ASM

FOOTER = <<-ASM
\t# exit with the result as %eax
\tmovl %eax, %edi       # set the exit code into %edi
\tmovl $0x2000001, %eax # system call $1 with $0x2000000 offset
\tsyscall
ASM

$input  = STDIN
$output = STDOUT

$lookahead = nil
$stackdepth = 0

# Internal: Read a character from input stream
def lookahead(input: $input)
  $lookahead = input.getc
end

# Inernal: Report an error.
def report_error(error, out: $output)
  out.puts
  out.puts "Error: #{error}."
end

# Inernal: Report an error and halt.
def abort(s)
  report_error(s)
  exit 1
end

# Internal: Report What Was Expected
def expected(s)
  abort "#{s} Expected"
end

# Internal : Match a Specific Input Character
def match(x)
  if $lookahead == x
    lookahead
    skip_white
  else
    expected x
  end
end

# Internal: Recognize an Alpha Character.
#
# Returns true if the string character is an alpha.
def is_alpha(c)
  c =~ /[a-z]/i
end

# Internal: Recognize a Decimal Digit
#
# Returns true if the string character is a digit.
def is_digit(c)
  c =~ /[0-9]/
end

# Internal: Recognize an alphanumeric character.
#
# Returns true if the string character is either a digit or an alpha.
def is_alnum(c)
  is_alpha(c) || is_digit(c)
end

# Internal: Recognize whitespace.
#
# Returns true if the string character is a whitespace character.
def is_white(c)
  # c =~ /\s/
  ["\t", " "].include?(c)
end

def is_addop(c)
  ADDOPS.include?(c)
end

# Internal: Get an Identifier, and looks up the next character.
#
# Returns the alpha character String (prefixed with an underscore `_`).
def get_name
  token = ""

  return expected("Name") unless is_alpha($lookahead)

  while is_alnum($lookahead)
    token << $lookahead
    lookahead
  end

  skip_white

  "_#{token}"
end

# Internal: Get a Number
#
# Returns the digit character String.
def get_num
  value = ""

  return expected("Integer") unless is_digit($lookahead)

  while is_digit($lookahead)
    value << $lookahead
    lookahead
  end

  skip_white

  value
end

def skip_white
  while is_white($lookahead)
    lookahead
  end
end

# Internal: Output a String with Tab
def emit(s, out: $output)
  out.print(TAB, s)
end

# Internal: Output a String with Tab and CRLF
def emitln(s, out: $output)
   emit(s, out: out)
   out.puts
end

def emit_section(section, out: $output)
  case section
  when :data
    out.print(".section __DATA,__data")
  when :text
    out.print(".section __TEXT,__text")
  else
    expected ":data, :text section"
  end
  out.puts
end

def comment(s, out: $output)
  emit("# #{s}", out: out)
  out.puts
end

def ident
  name = get_name
  comment name

  if $lookahead == "("
    match "("
    match ")"
    # FIXME: investigate defining/calling a function and replace this NOOP stub
    emitln "# BSR #{name}"
    emitln "movl $0x0, %eax"
  else
    define_variable name # defaults to 0
    emitln "movl #{name}(%rip), %eax"
  end
end

#   <factor> ::= <number> | (<expression>) | <variable>
def factor
  case
  when $lookahead == '('
    match "("
    comment "("
    alloc_stack
    expression
    free_stack
    match ")"
    comment ")"
  when is_alpha($lookahead)
    ident
  else
    num = get_num
    comment num
    emitln "movl $#{num}, %eax"
  end
end

# FIXME: figure out a better way to define variables when needed, see if we can
# define the label/symbol without setting a default value, and maybe validate
# that they've been assigned before being used in the first place.
def define_variable(name)
  emit_section :data
  emit "#{name}: .long 0x0\n"
  emit_section :text
end

def multiply
  match "*"
  comment "*"
  factor
  emitln "imul -(0x8*#{$stackdepth})(%rsp), %eax"
end

# Internal: Divide the dividend on the stack with the divisor in %eax.
#
# > Division requires special arrangements
# source: https://www.lri.fr/~filliatr/ens/compil/x86-64.pdf
#
# Division requires the divisor to be in %eax *and* %edx. Since we're only
# worried about 32bit values (right now), we put our 32bit value on the stack
# -0x8(%rsp) into %eax and use cltd to convert the long into a double long. But
# first we move the divisor into %ebx because it's available and we need to
# make %eax available for the dividend.
#
# Division leaves the value in %eax and nothing on the stack.
def divide
  match "/"
  comment "/"
  factor
  emitln "movl %eax, %ebx"
  emitln "movl -(0x8*#{$stackdepth})(%rsp), %eax"
  emitln "cltd"
  emitln "idivl %ebx"
end

# Internal: Parse and Translate a Math Expression.
#
#   <term> ::= <factor>  [ <mulop> <factor> ]*
def term
  factor
  while MULOPS.include?($lookahead)
    emitln "movl %eax, -(0x8*#{$stackdepth})(%rsp)"
    case $lookahead
    when "*"
      multiply
    when "/"
      divide
    else
      expected "mulop"
    end
  end
end

# Internal: Recognize and Translate an Add
def add
  match "+"
  comment "+"
  term
  emitln "addl -(0x8*#{$stackdepth})(%rsp), %eax"
end

# Internal: Recognize and Translate a Subtract
def subtract
  match "-"
  comment "-"
  term
  emitln "subl -(0x8*#{$stackdepth})(%rsp), %eax"
  emitln "neg %eax"
end

# Internal: Parse and Translate an Expression
#
#   <expression> ::= <term> [<addop> <term>]*
def expression
  if is_addop($lookahead)
    emitln "xor %eax, %eax"
  else
    term
  end

  while is_addop($lookahead)
    emitln "movl %eax, -(0x8*#{$stackdepth})(%rsp)"
    case $lookahead
    when "+"
      add
    when "-"
      subtract
    else
      expected "Addop"
    end
  end
end

# Internal: Parse and handle assigning an expression's value to a variable.
#
#   <Ident> = <Expression>
def assignment
  name = get_name
  comment name
  define_variable name
  match "="
  comment "="
  expression
  emitln "leaq #{name}(%rip), %rdx"
  emitln "movl %eax, (%rdx)"
end

def alloc_stack
  $stackdepth += 1

  comment "make space for 8byte (64bit) value at #{$stackdepth}"
  emitln "subq $0x8, %rsp"
end

def free_stack
  comment "free space for 8byte (64bit) value at #{$stackdepth}"
  emitln "addq $0x8, %rsp"

  $stackdepth -= 1
end

def assembler_header(out: $output)
  out.puts HEADER
end

def assembler_footer(out: $output)
  out.puts
  out.puts FOOTER
end

def init
  alloc_stack
  lookahead
  skip_white
end

def main
  assembler_header

  init

  assignment

  return expected("Newline") if $lookahead != "\n"

  assembler_footer

  debug_dump if ENV.key?('DEBUG')
end

def debug_dump
  STDERR.puts [:lookahead, $lookahead].inspect
end

if $0 == __FILE__
  main
end
