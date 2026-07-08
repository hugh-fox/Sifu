# Language Reference

## Sifu-Specific Terminology, Parsing and Grammar
Sifu has an LL(1) grammar.

#### Nouns

- Atom - anything not separated by the lexer, such as `1`, `"asd"`, or `Foo`.
- Term - a single atom or nested pattern, separated by whitespace like `1`, `(Fn 123 "asd")`,
or `Foo`.
- Sub-term: a term inside a pattern, which is the containing term
- Key - an uppercase word atom
- Var - a lowercase word atom, matches and stores a match-specific term. During
rewriting, whenever the var is encountered again, it is rewritten to this
term. A Var pattern matches exactly one term, including nested patterns. It
only makes sense to match anything after trying to match something specific, so
Vars always successfully match (if there is a Var) after a Key or Subpat match
fails.
- Pattern - a list of terms, nested by parenthesis
- Tuple - anything surrounded by parenthesis
- Ast - one possible encoding of the intermediate representation required to parse Sifu semantics from text 
- Trie - a trie of patterns, nested by braces like `{ F, G -> 2 }`. Simple
tries form sets like `{1, 2, 3}` or hashmaps like `{F -> 1, G -> 2}`.
- Match - the result of evaluating a match, consisting of selecting the lowest index that is equal or a variable and then rewriting its value with any bound variables.
- Index - starting from 0, the nth top-level entry in a trie.
- Height - the level of nesting in a pattern or trie. Used by the structurally recursive evaluator to guarantee termination while matching at the same index.
- Length - the number of terms in a pattern, or entries in a trie.
- Match Op: an expression of the form `into : from` where
    - *into* is the expression to match into
    - *from* is the trie to match from
- Evaluate - repeated applications of a series of evaluators at each level of nesting.
- Evaluator - a function from `Pattern, anytype -> Pattern` which stores context, like bounds, between calls. Typically involves repeated matches, and is responsible for termination (i.e., a lower bound evaluator sets its lower bound to each match index to ensure eventual termination).
- Arrow
  1. an expression of the form `from -> into` where
    - from is the expression to rewrite from, which was matched
    - into is the expression to rewrite into, which is the result
  2. an encoding in a trie that represents an arrow after its insertion in
that pattern, like the arrow in `{F -> 123}`
- Value - the right side of an arrow, the part rewritten to
- Commas - special operator that delimits separate keys/arrows in tries
- Newline - separates pattern, unless before a trailing operator or within a nested
paren or brace.
- Quotes - code surrounded with (`). Not evaluated, only treated as data.
- Ops - a special kind of Term that has different parsing
- Infix - shorthand for an Op that is user defined
- Builtin - a builtin operator (there are no keywords). Builtins are the only
operators with precedence in Sifu. This precedence is as follows: 
> semicolons < long match, long arrow < comma < infix < short match, short arrow
  - Commas and Semis - these delimit separate expressions within a specific level of nesting. Commas are high precedence, while Semicolons are low. 

### Parsing

Parsing begins at the top level with Tries. A Trie is zero or more comma or line separated values. Commas are a kind of operator, and operators are a pattern with their token as the first value, followed by everything after them until a closing trie, pattern, or another operator. 

Multiple operators in the same pattern are similar to a linked list, because each operator starts a new term at the end of the previous operator's pattern. For example, `1 2, 3 4, 5 6`, is parsed as `(1 2 , (3 4 , (5 6)))` with parentheses denoting patterns.

By default, after beginning with a trie at top level everything is assumed to be a pattern, each of which are entered into the trie. This therefore requires addressing how to parse nested patterns and tries, as ambiguity naturally arises from any assumption. A nested pattern or trie term singleton following an operator must be differentiated with a pattern of terms, which may also be nested patterns or tries. For example, `A -> {}` shouldn't be parsed as `A -> ({})` with parentheses denoting patterns. Rather, while parsing a pattern is always the default, if the nested pattern or trie begins and ends with an operator or closing token, like a newline, it is parsed as a singleton. The purpose of this exception is to make typical code more intuitive (wysiwyg), for example: `Key -> { Value }` shouldn't be parsed as `Key -> ({ Value })` with explicit parentheses, but rather a pattern mapping to a trie directly (no redundant pattern in between). 

#### Verbs

- Select - the first phase during matching when looking up an expression that
matches keys in the trie

---

## Expressions

### Terms

### Pattern

### Parentheses

## Type Checking as Pattern matching on Patterns

To type check a Sifu program, ensure each expression will match at least once.

For example, consider the following definitions modeling boolean algebra:
```
Bool => { True, False }

And (True : Bool) (True : Bool) => True
And (_ : Bool) (_ : Bool) => False 
```
Then an expression like this should also have type `Bool`:
```
And (False) (True)
```
To type check it, we need to show each argument will match its parameter at least once. Both `False : Bool` and `True : Bool` match, so the match is checked. The resulting value must also do that same, and should be evaluated to see whether it is of type bool as well. If compiled, this step would be interpreted by the compiler at compile time, and then elided for optimization.
