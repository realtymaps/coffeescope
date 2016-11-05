"use strict"
globals = require "globals"

Declaration = require "./Declaration"
Scope = require "./Scope"


module.exports = class ScopeLinter
    @default: -> defaultLinter  # initialized on the bottom of the file

    lint: (root, options) =>
        global = new Scope()
        builtins = new Declaration("Builtin", root, {line: 0, column: 0})

        envs = options["environments"]
        if typeof envs is "string"
            envs = [envs]
        for env in envs or []
            for own name of env
                global.write(name, root, builtins)

        custom = options["globals"]
        if typeof custom is "string"
            custom = [custom]
        for name in custom or []
            global.write(name, root, builtins)

        @newScope global, =>
            @visit(root)

        errors = global.errors(options)
        errors.sort((a, b) -> a.lineNumber - b.lineNumber)
        return errors

    # the scope available in the current node; a new scope is pushed every
    # time a Code node is encountered and popped every time a Code node has
    # been completely visited.
    scope: null

    # a list of functions that should be called in a separate sub-scope as
    # soon as the current scope is completely visited;
    subscopes: null

    newScope: (scope, cb) =>
        # invokes `cb` in `scope`
        old = [@scope, @subscopes]
        @scope = scope
        @subscopes = []

        try
            cb()
            for fn in @subscopes
                @newScope(new Scope(@scope), fn)
        finally
            [@scope, @subscopes] = old
        undefined

    # the current declaration, if any
    declaration: null

    newDeclaration: (type, node, cb) =>
        old = @declaration
        try
            if cb?
                @declaration = new Declaration(type, node, {
                    line: node.locationData["last_line"],
                    column: node.locationData["last_column"]
                })
            else
                cb = type
                @declaration = null
            cb()
        finally
            @declaration = old

    visit: (node) =>
        if not node?
            return

        handler = this["visit#{node.constructor.name}"]
        if handler?  # assume the handler will visit its children
            handler(node)
        else  # walk through all child nodes
            node.eachChild(@visit)
        undefined

    visitAssign: (node) =>
        @newDeclaration @declaration?.type or "Variable", node, =>
            @visit(node.variable)
        @visit(node.value)
        undefined

    visitCall: (node) =>
        if node.do and node.variable.constructor.name is "Code"
            # this calls a immediate function with a do statement; the extra
            # check is to eliminate `do fn` expressions which are syntactic
            # sugar for `fn()`
            @visitCode(node.variable, "Do")

            for arg in node.args or []
                if arg.name?
                    # this named variable has now been read in this scope
                    # because it was forwarded to the inner function
                    @scope.read(arg.name.value, arg)
                else
                    @visit(arg)

        else
            node.eachChild(@visit)
        undefined

    visitClass: (node) =>
        if node.variable? and node.variable.isAssignable()
            # a named class produces a variable in the local scope and in this
            # regard acts like an assignment statement
            @visit(node.variable)
            if @declaration
                # allow named classes that are part of assignment statements
                # without requiring their names to be read
                @scope.read(node.variable.base.value, node.variable)

        @visit(node.parent)
        @subscopes.push =>
            @visit(node.body)
        undefined

    visitCode: (node, type = "Argument") =>
        @subscopes.push =>
            # `arguments` is always a `Do` because it shadows by design
            @scope.write("arguments", node, new Declaration("Do", node, {
                line: node.body.locationData["first_line"]
                column: node.body.locationData["first_column"]
            }))
            for param in node.params or []
                @newDeclaration type, param, =>
                    @visit(param.name)
                @visit(param.value)
            @visit(node.body)
        undefined

    visitFor: (node) =>
        @newDeclaration "For", node, =>
            @visit(node.name)
            @visit(node.index)
        node.eachChild(@visit)
        undefined

    visitOp: (node) =>
        # unary ops ++ and -- should perform both a read and a write
        if node.operator in ["++", "--"]
            if not node.first.hasProperties()
                @scope.write(node.first.base.value, node.first,
                             new Declaration("Variable", node))
            @visit(node.first)
        else
            node.eachChild(@visit)

    visitTry: (node) =>
        @visit(node.attempt)
        if err = node.errorVariable?
            @newDeclaration "Exception", err, =>
                @visit(err)
        @visit(node.recovery)
        @visit(node.ensure)
        undefined

    visitValue: (node) =>
        if node.base.constructor.name is "IdentifierLiteral"
            name = node.base.value
            if not @declaration? or node.hasProperties()
                @scope.read(name, node)
            else
                @scope.write(name, node, @declaration)

            if node.hasProperties()
                @newDeclaration =>
                    for prop in node.properties
                        if prop.constructor.name isnt "Access"
                            @visit(prop)
        else if node.base.constructor.name is "Call"
            # possible assign-to-result constructs: foo(bar).baz = qux
            @newDeclaration =>
                node.eachChild(@visit)
        else
            # destructured assignment
            node.eachChild(@visit)
        undefined


defaultLinter = new ScopeLinter()
