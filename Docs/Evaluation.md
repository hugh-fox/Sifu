# Evaluation

While different evaluation strategies can have different cycles, there are a few basic forms they can take. Below are some examples of each and how they are handled in Sifu.

All evaluators prioritize lower matches. For example, in the case of variables or exact matches, the lower index is chosen. In the pattern below, `A` will evaluate to `B`:
```
x -> B
A -> C
```

In the evaluators below, variables and variable patterns in a pattern being _matched_ are compared by name literally to entries in the trie. Future, more complicated evaluators may match them with anything or with other strategies.

In Sifu, all forms of evaluation are essentially a repeated match and rewrite of a pattern against a trie until there are no more matches. On its own, this kind of repeated pattern matching has infinite cycles. To prevent this, every Sifu program is ordered from lower indices to higher (top to bottom). During evaluation, cycles are prevented by either lowering or raising bounds for which the next match must happen within. For more complicated forms of evaluation, like those supporting structural recursion, the bounds can be kept the same over multiple iterations if there is some guarantee of progress being made.


1. A looping cycle of two or more indices which evaluate to each other. This kind is inherent to all evaluators in Sifu.
    ```
    A -> B
    B -> A
    ```
    Here of course index 0 evaluates to 1, which evaluates back to 0.

    This kind of cycle is solved by tracking a lower bound, starting from 0, only matching the trie at indices at or after the bound, and afterwards updating the bound to the index matched incremented by one. This is preferential, as being the most prevelant and common form of cycle it deserves the more intuitive and natural limiting. Raising a lower bound causes the program to flow downwards as it is written, which is easier to reason about.

2. In evaluators that support structural recursion, a rule can potentially match itself with its original pattern. There are two variants, the first is simply
    a pattern which matches itself, like `A -> A`, and is also present in any evaluator. However, it is also solved by raising the lower-bound (because equal heights aren't structurally recursive), so it doesn't require any further handling.
    
    The non-trivial form typically is seen with variables:
    ```
    Sum (x, *xs) -> x + Sum (*xs)
    ```
    Such a rule will always terminate, but what happens if the evaluation side isn't simpler?
    ```
    Sum (x, *xs) -> x + Sum (x, *xs)
    ```
    This rule will loop forever, generating an infinitely long sequence of `x + x + ...`. The current evaluator does not support unlimited recursion, but rather a limited form of structural recursion based on the height (or depth) of the pattern matched and the pattern rewritten. In this form, recursion happens (i.e. the matched pattern is rewritten) only when the resulting rewritten pattern has a combined level of nesting (including a level created from any operators' rhs) _less than_ the original matched pattern. In this way, the finite structure of the pattern being matched is tied to the computation, guaranteeing it to be finite.
    
    Additionally, the structurally recursive calls are limited by tracking an upper bound as well. The current index is passed as the upper bound to the structurally recursive calls, ensuring they cannot match anything after the current index.
    
    Note that once checked, if the rewritten pattern fails this test, it is discarded and the original match is kept instead. Then, evaluation continues with the current bounds (which haven't changed during structural iterations), however the lower bound is incremented, exhausting the index for the rest of the evaluation.

3. In evaluators that support nested recursion, each level of nesting allows matching up to, but not including, the current index (the recursive evaluation is called with a lower bound of 0). This form of recursion is also handled by recursing with an upper bound equal to the current index (upper bounds or exclusive, lower bounds are inclusive).
    ```
    A -> (A)
    ```
    Nesting recursion is most useful if it occurs for both the head and tail of a list, for example:
    ```
    F x --> G x
    (x, *xs) --> F x, (*xs)
    ```
    Evaluating `(1, 2, 3,)` against this trie should give `G 1, G 2, G 3, ()` by matching each head of the rewritten list with the lower rule 0.
    
---

# Specific Evaluators


## Match

A simple evaluator that just performs a single match and rewrite step, evaluating to the rewritten pattern and an index for which it was matched.

## Evaluate Complete

A recursive evaluator that only matches a pattern completely, without partial matches.
It supports structural and nested recursion. 

## Evaluate Concatenative

Like Evaluate-Complete, but adds a step for when a pattern doesn't match. It will then increment an index in that pattern and evaluate the rest, appending it to the original prefix which didn't match.