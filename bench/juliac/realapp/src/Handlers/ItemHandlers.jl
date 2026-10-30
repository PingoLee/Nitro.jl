module ItemHandlers

using HTTP
using Nitro
import ..appM

struct ItemIn
    name::String
    category::String
    quantity::Int
end

struct SearchQuery
    limit::Int
    min_qty::Int
end

const ITEM_FIELDS = ("id", "name", "category", "quantity")

# A model read, list: `objects.filter(…)`, a fixed first page, so the write route cannot grow it.
list_items(req::HTTP.Request) =
    Res.json(appM.Item.objects.filter("id__@lte" => 20).values(ITEM_FIELDS...).order_by("id").list(:dict))

# A model read, by id.
function get_item(req::HTTP.Request, id::Int)
    rows = appM.Item.objects.filter("id" => id).values(ITEM_FIELDS...).list(:dict)
    isempty(rows) && return Res.json(Dict("error" => "not found"); status = 404)
    return Res.json(only(rows))
end

# A write.
function create_item(req::HTTP.Request, body::Json{ItemIn})
    item = body.payload
    appM.Item.objects.create("name" => item.name, "category" => item.category,
                             "quantity" => item.quantity)
    return Res.json(Dict("created" => item.name); status = 201)
end

# `Json{T}` with `validate`: bound and checked, nothing stored.
validated(req::HTTP.Request, body = Json{ItemIn}(i -> i.quantity >= 0 && !isempty(i.name))) =
    Res.json(Dict("name" => body.payload.name, "quantity" => body.payload.quantity))

# `Query{T}` and a path parameter.
search(req::HTTP.Request, category::String, q::Query{SearchQuery}) =
    Res.json(Dict("category" => category, "limit" => q.payload.limit, "min_qty" => q.payload.min_qty))

end # module
