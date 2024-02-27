# Sifu, A Concatenative Language Based on Tries


### Main Ideas
  
  - Computation is a pattern match

  - No turing completeness, everything terminates by matching entries less than
    (or recursive/equal, but with structural simplification) to themselves

  - Everything is a pattern map (like tries, but lookups have to deal with sub-lookups)

  - Core language is pattern-matching rewriter
    - triemap entries (`->`) and triemap matches (`:`)
    - multi triemap entries (`=>`) and multi triemap matches (`::`)
    - keywords are `->`, `:`, `=>`, `::`, `,`, `;`, `()`, and `{}`
    - match / set membership / typeof is the same thing (`:`)
    - source files are just triemaps with entries separated by newlines
    - any characters are valid to the parser (punctuation chars are values, like
in Forth)
    - values are literals, i.e. upper-case idents, ints, and match only themselves
    - vars match anything (lower-case idents)

  - Values and Variables
    - variables are just entries `x -> 2` and match anything
    - values are as well `Val1 -> 2` and are treated as literals (strings are just an escaped value)

  - Emergent Types
    - types are triemaps of values
    - records are types of types
    - record fields are type level entries
    - hashmaps of types can be used to implement row types
    - type checking is a pattern match
    - dependent types are patterns of types with variables

  - Compiler builds on the core language, using it as a library
    - complilation is creating perfect hashmaps from dynamic ones

## Examples
```python
# Implement some simple types
Ord -> { Gt, Eq, Lt }
Bool -> { True, False }

# A function `IsEq` that takes an ord, and returns True if it is Eq. `_` is
# just another var, meant to be unused. 
IsEq Eq -> True
IsEq _ -> False

# This function compares bools using Case, a function that takes a list of
# entries and another arg and applies them against the arg until one matches.
# The matches on the lhs of the entries are sub-matches, which are matched
# recursively, then bind their computations to the variables `b1` and `b2`.
# If either one doesn't match at least once, the parent match doesn't as
# well.
Compare (b1 : Bool) (b2 : Bool) -> Case [
    (True, False) -> Gt,
    (False, True) -> Lt,
    _ -> Eq,
  ] (b1, b2)
```


## Roadmap

### Core Language
  
  - [x] Parser/Lexer
    - [x] Lexer (Text → Token)
    - [ ] Parser (Tokens → AST)
      - [ ] Newline delimited apps for top level and operators' rhs
      - [ ] Nested apps for parentheses
      - [ ] Patterns
      - [ ] Infix
      - [ ] Match
      - [ ] Arrow
      - Syntax
        - [x] Apps (parens)
        - [x] Patterns (braces)

  - [ ] Patterns
    - [x] Definition
    - [x] Construction (AST → Patterns)
      - [ ] Error handling
    - [x] Matching
      - [x] Vals
      - [ ] Apps
      - [ ] Vars
      - [ ] Multi

### Sifu Interpreter

  - [ ] REPL
    - [x] Add entries into a global pattern
    - [x] Update entries
    - [ ] Load files
    - [ ] REPL specific keywords (delete entry, etc.)

  - [ ] Effects / FFI
    - [ ] Driver API
    - [ ] Builtin Patterns
    - [ ] File I/O

  - [ ] Basic Stdlib using the Core Language

- ### Sifu Compiler

  - [ ] Effects / FFI
    - [ ] Effect analysis
      - [ ] Tracking
      - [ ] Propagation
    - [ ] User error reporting
      
  - [ ] Type-checking
  
  - [ ] Codegen
    - [ ] Perfect Hashmaps / Conversion to switch statements


---



Thanks to Luukdegram for giving me a starting point with their compiler [Luf](https://github.com/Luukdegram/luf)
