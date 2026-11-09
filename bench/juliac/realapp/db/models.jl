module models

import PormG.Models
import PormG.Models: RESTRICT, CASCADE, SET_NULL, SET_DEFAULT, DO_NOTHING, PROTECT

# One neutral model for #744's model read and write routes. A typed binding (PormG #1650): a
# plain one is an untyped global read on every `appM.Item`, which a trimmed image cannot follow.
Item::Models.ModelType = Models.Model("items",
    id       = Models.IDField(),
    name     = Models.CharField(max_length=100),
    category = Models.CharField(max_length=50),
    quantity = Models.IntegerField(),
)

# The model set `set_models` registers (PormG #1602); `main` binds it.
Models.@models Item

end
