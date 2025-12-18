# Sifu, A Concatenative Language Based on Tries

See some examples here: [playground](https://sifu-lang.pages.dev/playground)

---

### About

Sifu is a Turing-incomplete programming language based on concatenative trie
matching. It aims to fill a niche for solving problems with finite time/
memory requirements. Any program in Sifu will terminate, making it easier to
reason about its effects. This also provides the possibility of proving
arbitrary things about programs for safety-critical software, as the halting
problem doesn't apply.

The parser is implemented as a standalone zig module here [tree-sitter-sifu](https://github.com/hugh-fox/Tree-Sitter-Sifu).

---

### Main Ideas
  
  - Computation is an ordered trie match. Ordering is important, because it
  ensures there is always a clear path to completion.

  - No turing completeness, everything terminates by matching entries whose
    index in the map is less than (or recursive/equal, but with structural
    recursion) until a fixed point (any remaining indices contain no more
    matches).

  - Everything is a trie map (like tries, but lookups have to deal with sub-lookups)

  - Core language is trie-matching rewriter
    - trie entries (`->`) and pattern matches (`:`)
    - keywords are `->`, `:`, `,`, `()`, and `{}`
    - keywords have lower precedence versions:  `-->`, `::`, `;`,
    - match / set membership / typeof is the same thing (`:`)
    - source files are just triemaps with entries separated by newlines
    - any characters are valid to the parser (punctuation chars are values, like
      in Forth)
    - code can be quoted with backticks (`\``) like in Lisps, to treat it as
data instead of evaluating it.
    - values are literals, i.e. upper-case idents, ints, and match only themselves
    - vars match anything (lower-case idents)

  - Stdlib functions
    - multi entries (`=>`) and multi triemap matches (`::`). These are
      implemented by continuously appending a single var match of the current
      scope until the top of the scope is reached (each pattern in the trie is
      matched)
  - Values and Variables
    - variables are just entries `x -> 2` and match anything
    - values are as well `Val1 -> 2` and are treated as literals (strings are just an escaped value)

  - Emergent Types
    - types are triemaps of values
    - records are types of types
    - record fields are type level entries
    - hashmaps of types can be used to implement row types
    - type checking is a trie match
    - dependent types are tries of types with variables

  - Compiler builds on the core language, using it as a library
    - complilation is creating perfect hashmaps from dynamic ones




## Roadmap

### Core Language
  
  - [x] Parser/Lexer
    - [x] Lexer (Text → Token)
    - [ ] Parser (Tokens → AST)
      - [x] Non-recursive parsing
      - [ ] Newline delimited pattern for top level and operators' rhs
      - [x] Nested pattern for parentheses
      - [ ] Patterns
      - [x] Infix
      - [x] Match
      - [x] Arrow
      - Syntax
        - [x] Nested patterns (parens)
        - [x] Tries (braces)

  - [ ] Patterns
    - [x] Definition
    - [x] Construction (AST → Patterns)
      - [ ] Error handling
    - [x] Matching
      - [x] Vals
      - [x] Trees
      - [x] Vars
    - [ ] Evaluation
      - [ ] Index-based limiting
      - [ ] Multi

### Sifu Interpreter

  - [ ] REPL
    - [x] Add entries into a global trie
    - [x] Update entries
    - [ ] Load files
    - [ ] REPL specific keywords (delete entry, etc.)

  - [ ] Effects / FFI
    - [ ] Driver API
    - [ ] Builtin Tries
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

## Implementation FAQ

If the ASTs are hashable, why not use a hashmap instead of a trie of tries?

> Hashmaps or tries would work for inserting, but granular matching wouldn't.
> Matching variables would also be tricky to implement.

---

Thanks to Luukdegram for giving me a starting point with their compiler [Luf](https://github.com/Luukdegram/luf)
