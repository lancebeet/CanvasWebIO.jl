module CanvasWebIO

using WebIO, JSExpr, Observables

export Canvas, addmovable!, addclickable!, addstatic!

mutable struct Canvas
    w::WebIO.Scope
    size::Array{Int64, 1}
    objects::Array{WebIO.Node, 1}
    getter::Dict
    id::String
    handler::Observables.Observable
    selection::Observables.Observable
    synced::Bool # synced=true => julia listeners called on mousemove, not just drop
end

function Canvas(size::Array{Int64,1}, synced=false)
    w = Scope(imports=["/pkg/CanvasWebIO/helpers.js"])
    handler = Observable(w, "handler", ["id", 0, 0])
    selection = Observable(w, "selection", "id")
    getter = Dict()
    id = WebIO.newid("canvas")
    on(selection) do val
        val
    end
    on(handler) do val
        selection[] = val[1]
        if val[1] in keys(getter)
            getter[val[1]][] = Int.(floor.(val[2:3]))
        else
            println("Failed to assign value $(val[2:3]) to $(val[1])")
        end
    end
    Canvas(w, size, Array{WebIO.Node,1}(), getter, id, handler, selection, synced)
end

function Canvas()
    Canvas([800,800])
end

function Canvas(synced::Bool)
    Canvas([800,800], synced)
end

function Base.getindex(canvas::Canvas, i)
    canvas.getter[i]
end

function (canvas::Canvas)()

    # js function setp sets the position of the object named name to the position of the mouse
    # returns the [draggable, xpos, ypos] where draggable is whether the object was movable,
    # and xpos,ypos the new position of the object
    #
    # Transform parser from https://stackoverflow.com/a/17838403

    canvas_events = Dict()

    handler = canvas.handler
    synced  = canvas.synced

    canvas_events["mousemove"]  = @js function(event)
        event.preventDefault()
        event.stopPropagation()
        @var name = document.getElementById($(canvas.id)).getAttribute("data-selected")
        @var pos
        if name!=""
            pos = setp(event, name)
            if(pos[0]) #is dragged
                document.getElementById($(canvas.id)).setAttribute("is-dragged", true)
                if($synced)
                    $handler[] = [name, Math.round(pos[1]), Math.round(pos[2])]
                end
            end
        end
    end

    canvas_events["mouseup"] = @js function(event)
        event.preventDefault()
        event.stopPropagation()
        console.log("canvas click")
        @var name = document.getElementById($(canvas.id)).getAttribute("data-selected")
        @var pos
        if name!=""
            pos = setp(event, name)
            if document.getElementById($(canvas.id)).getAttribute("is-dragged")=="true"
                $handler[] = [name, parseFloat(pos[1]), parseFloat(pos[2])]
                document.getElementById(name).style.stroke = "none"
                document.getElementById($(canvas.id)).setAttribute("data-selected", "")
                document.getElementById($(canvas.id)).setAttribute("is-dragged", false)
            end
        end
    end

    canvas.w(dom"svg:svg[id = $(canvas.id),
        height = $(canvas.size[1]),
        width = $(canvas.size[2])]"(
                                    canvas.objects...,
                                    attributes = Dict("data-selected" => "",
                                                     "is-dragged" => false),
                                    events = canvas_events))
end

"""
addclickable!(canvas::Canvas, svg::WebIO.Node)

Adds a clickable (as in, can be clicked but not moved) object to the canvas based on the svg template. If the template has an id, this will be given to the canvas object, and the object will be associated with the id as a string (canvas[id] accesses the associated observable etc). If the template has no id, one will be generated. Note that the stroke property will be overwritten.
"""
function addclickable!(canvas::Canvas, svg::WebIO.Node)
    attr = svg.props[:attributes]
    children = svg.children
    if "id" in keys(attr)
        id = attr["id"]
    else
        id = WebIO.newid("svg")
    end
    selection = canvas.selection
    clickable_events = Dict()
    clickable_events["click"]  = @js function(event)
        name = document.getElementById($(canvas.id)).getAttribute("data-selected")
        #selected_obj
        if name == this.id
            this.style.stroke = "none"
            document.getElementById($(canvas.id)).setAttribute("data-selected", "")
        else
            if name != ""
                selected_obj = document.getElementById(name)
                selected_obj.style.stroke = "none"
            end
            this.style.stroke = "green" #Change this later
            this.style.strokeWidth = 2 #Change this later
            document.getElementById($(canvas.id)).setAttribute("data-selected", this.id)
            $selection[] = this.id
        end
    end
    push!(canvas.objects,
          Node(svg.instanceof, children..., attributes=attr, events=clickable_events))
end
"""
addmovable!(canvas::Canvas, svg::WebIO.Node, lock=" ")

Adds a movable object to the canvas based on the svg template. If the template has an id, this will be given to the canvas object, and the object will be associated with the id as a string (canvas[id] accesses the associated observable etc). If the template has no id, one will be generated. Note that the stroke property will be overwritten.

The optional lock argument allows locking of an axis. Setting lock="x" will lock the movable's x value, so it can only be moved up and down. Similarly, lock="y" will only permit movements to the left and right.
"""
function addmovable!(canvas::Canvas, svg::WebIO.Node, lock=" ")
    attr = svg.props[:attributes]
    if svg.instanceof.tag!=:g
        newattr = Dict()
        if "id" in keys(attr)
            newattr["id"] = attr["id"]
        else
            newattr["id"] = WebIO.newid("svg")
        end
        attr["id"] = WebIO.newid("subsvg")
        if haskey(attr, "x") && haskey(attr, "y") #Rectangle etc
            newattr["transform"] = "translate($(attr["x"]),$(attr["y"]))"
            attr["x"] = "$(-parse(attr["width"])/2)"
            attr["y"] = "$(-parse(attr["height"])/2)"
        elseif haskey(attr, "cx") && haskey(attr, "cy") #Circle
            newattr["transform"] = "translate($(attr["cx"]),$(attr["cy"]))"
            attr["cx"] = "0.0"
            attr["cy"] = "0.0"
        else
            newattr["transform"] = "translate($(attr["cx"]),$(attr["cy"]))" #undefined object
        end
        return addmovable!(canvas, dom"svg:g"(svg, attributes=newattr), lock)
    end
    if :style in keys(svg.props)
        style = svg.props[:style]
    else
        style = Dict()
    end
    children = svg.children
    if "id" in keys(attr)
        id = attr["id"]
    else
        id = WebIO.newid("svg")
        attr["id"] = id
    end
    attr["data-lock"] = lock
    if svg.instanceof.tag==:g
        coo = [0.0, 0.0]
        try
            coo .= parse.(Float64, match(r"translate\((.*?),(.*?)\)",
                                         attr["transform"]).captures)
        catch
            println("Failed to get position of $id, setting default")
        end
        pos = Observable(canvas.w, id, coo)
    else
        error("Only <g> objects allowed")
    end

    push!(pos.listeners, (x)->(x))
    canvas.getter[id] = pos

    handler = canvas.handler
    attr["draggable"] = "true"
    style[:cursor] = "move"
    movable_events = Dict()

    movable_events["mousedown"]  = @js function(event)
        event.stopPropagation()
        event.preventDefault()
        console.log("clicking", this.id)
        @var name = document.getElementById($(canvas.id)).getAttribute("data-selected")
        @var pos
        if name == ""
            this.style.stroke = "red" #Change this later
            this.style.strokeWidth = 2 #Change this later
            document.getElementById($(canvas.id)).setAttribute("data-selected", this.id)
        else
            selected_obj = document.getElementById(name)
            selected_obj.style.stroke = "none"
            pos = setp(event,name)
            if(pos[0]) #is dragged
                $handler[] = [name, pos[1], pos[2]]
            end
            document.getElementById($(canvas.id)).setAttribute("data-selected", "")
            document.getElementById($(canvas.id)).setAttribute("is-dragged", false)
        end
    end
    node = Node(svg.instanceof, children..., attributes=attr, style=style, events=movable_events)
    push!(canvas.objects, node)
    node
end

"""
addstatic!(canvas::Canvas, svg::WebIO.Node)

Adds the svg object directly to the canvas.
"""
function addstatic!(canvas::Canvas, svg::WebIO.Node)
    push!(canvas.objects, svg)
end

"""
setindex_(canvas::Canvas, pos, i::String)

Sets the position of the object i to pos on the javascript side.
"""
function setindex_(canvas::Canvas, pos, i::String)
    evaljs(canvas.w, js""" setp_nonevent($pos, $i)""")
end

function Base.setindex!(canvas::Canvas, val, i::String)
    setindex_(canvas::Canvas, val, i)
    canvas[i][] = val
end

end
