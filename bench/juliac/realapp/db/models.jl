module models

import PormG.Models
import PormG.Models: RESTRICT, CASCADE, SET_NULL, SET_DEFAULT, DO_NOTHING, PROTECT

# One neutral model for #744's model read and write routes.
Item = Models.Model("items",
    id       = Models.IDField(),
    name     = Models.CharField(max_length=100),
    category = Models.CharField(max_length=50),
    quantity = Models.IntegerField(),
)

end
