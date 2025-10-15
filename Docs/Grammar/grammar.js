module.exports = grammar({
    name: 'sifu',

    extras: $ => [
        /\s/,
        $.comment,
    ],

    conflicts: $ => [
        [$.pattern, $.trie],
        [$.term, $.pattern],
    ],

    rules: {
        source_file: $ => optional($.trie),

        // Comments
        comment: $ => token(seq('#', /.*/)),

        // Core structures
        trie: $ => choice(
            seq('{', optional($._trie_content), '}'),
            $._trie_content,
        ),

        _trie_content: $ => choice(
            $.comma_expr,
            $.semicolon_expr,
            $.long_match,
            $.long_arrow,
            $.infix,
            $.short_match,
            $.short_arrow,
            $.pattern,
        ),

        pattern: $ => prec.left(repeat1($.term)),

        term: $ => choice(
            $.atom,
            $.nested_pattern,
            $.nested_trie,
            $.quote,
        ),

        // Atoms
        atom: $ => choice(
            $.key,
            $.var,
            $.number,
            $.string,
            $.symbol,
        ),

        key: $ => /[A-Z][a-zA-Z0-9_]*/,
        var: $ => /[a-z][a-zA-Z0-9_]*/,
        number: $ => /[0-9]+(\.[0-9]+)?/,
        string: $ => /"([^"\\]|\\.)*"/,
        symbol: $ => /[!@$%^&*+=|<>?\/\\~`]+/,

        // Nested structures
        nested_pattern: $ => seq('(', optional($.pattern), ')'),

        nested_trie: $ => seq('{', optional($._trie_content), '}'),

        // Quotes
        quote: $ => seq('`', optional($.pattern), '`'),

        // Operators (by precedence, lowest to highest)

        // Semicolon - lowest precedence
        semicolon_expr: $ => prec.left(1, seq(
            field('left', choice($.pattern, $.comma_expr, $.long_match, $.long_arrow, $.infix, $.short_match, $.short_arrow)),
            ';',
            optional(field('right', $._trie_content))
        )),

        // Long match and long arrow
        long_match: $ => prec.left(2, seq(
            field('into', choice($.pattern, $.comma_expr)),
            ':',
            optional(field('from', choice($._trie_content, $.nested_trie)))
        )),

        long_arrow: $ => prec.left(2, seq(
            field('from', choice($.pattern, $.comma_expr)),
            '->',
            optional(field('into', choice($._trie_content, $.nested_trie)))
        )),

        // Comma - medium-low precedence
        comma_expr: $ => prec.left(3, seq(
            field('left', choice($.pattern, $.infix, $.short_match, $.short_arrow)),
            ',',
            optional(field('right', $._trie_content))
        )),

        // Infix - medium precedence
        infix: $ => prec.left(4, seq(
            field('left', choice($.pattern, $.short_match, $.short_arrow)),
            field('op', $.symbol),
            optional(field('right', choice($._trie_content, $.nested_pattern, $.nested_trie)))
        )),

        // Short match and short arrow - highest precedence
        short_match: $ => prec.left(5, seq(
            field('into', $.pattern),
            ':',
            optional(field('from', choice($._trie_content, $.nested_trie)))
        )),

        short_arrow: $ => prec.left(5, seq(
            field('from', $.pattern),
            '->',
            optional(field('into', choice($._trie_content, $.nested_trie)))
        )),
    }
});