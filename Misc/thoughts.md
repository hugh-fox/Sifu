Good languages have:
- Everything is a _. Things like composability, "only one way to do it", etc therefore come naturally.
- Complexity scales linearly, ideally with a low constant factor
  - No turing completeness. No program needs to compute infinite data of arbitrary form, so it doesn't need infinite expressive power.
- Tooling doesn't just react, it proactively suggests fixes, improvements, etc.
- It is easy to implement compiler errors that aren't ambiguous. If they are, either:
  - The language is needlessly complex, i.e. there is more than one way to do things (Haskell and C errors are great examples). Needless complexity arises when a language has too much power without enough constraining features. Rust has relatively good errors because although it has significant expressive power, it is very constrained. 
- There aren't many runtime checks, these are also a sign of too much complexity, because the compiler cannot easily perform them.
- May or may not have types: types typically perform the role of constrainment because most languages have so much power. In a language without as much power, types aren't necessary. For example, html, css, and other declarative languages.
- Compile fast and run fast. Either of these missing is a sign of, once again, too much complexity.
  - If it is difficult to translate a language into a turing machine, it has probably strayed too far from its underlying form of computation. It shouldn't just be simple to translate it into a turing machine, it should also be simple to do the reverse.
  - A heavily interpreted language is just an unfinished one. Its flexibility is redundant and/or excessive. Python, for example, enables you to redefine builtins (not just shadow them). The only reason this would be a good idea is if you were writing your own version of python.
- It doesn't have macros. A separate language for code generation is only necessary when a language doesn't have a way of talking about itself.

---

Our embarassing lack of good, universal transpilers for languages in the C
family is evidence of how bad they are. Even the translation of heavy OOP code
to C should just be a matter of mechanically replacing classes with vtables.

---

Functional programming languages aren't functional, they are lambda calculus or
immutable based, but not defined by mathematical functions. Their type systems
are, but the fundamental unit of computation isn't a mapping between sets. The
lambda calculus and immutablility both have nothing to do with sets.

---

Hashmaps should have been called functions, and functions should have been
called named blocks.

---

There are no tradeoffs in language design, there are only contradictions
and bad features.
- Can't seem to use your "general purpose" language for its own metaprogramming?
Its not really general purpose.
- Can't make x feature fast? Yet, under the hood, it introduces _more_ things
to compute?

---

It is easy to confuse complexity with hidden information. It is, by definition, no simple matter to increase true complexity.
