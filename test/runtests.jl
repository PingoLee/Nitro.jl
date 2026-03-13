module RunTests 

include("constants.jl"); using .Constants
include("test_utils.jl"); using .TestUtils

# #### Security & Robustness ####

include("securitytests.jl")

# #### Extension Tests ####

include("extensions/timezonetests.jl")
include("extensions/templatingtests.jl")
include("extensions/protobuf/protobuftests.jl")
include("extensions/cryptotests.jl")


#### Sepcial Handler Tests ####

include("ssetests.jl")
include("websockettests.jl")
include("streamingtests.jl")
include("handlertests.jl")

#### Core Tests ####
include("utiltests.jl")
include("cookiestests.jl")
include("sessiontests.jl")
include("sessionstores_tests.jl")
include("test_reexports.jl")
include("precompilationtest.jl")
include("extractortests.jl")
include("rendertests.jl")
include("bodyparsertests.jl")
include("ergonomics_tests.jl")
include("oxidise.jl")
include("instancetests.jl")
include("paralleltests.jl")
include("middlewaretests.jl")
include("appcontexttests.jl")
include("path_prefix_tests.jl")
include("routingtests.jl")
include("originaltests.jl")
include("spatests.jl")
include("dx_tests.jl")
include("auth_module_tests.jl")
include("auth_tests.jl")
include("revise.jl")

#### Scenario Tests ####
include("./scenarios/thunderingherd.jl")

#### Prebuilt Middleware Tests ####
include("middleware/extract_ip_tests.jl")
include("middleware/ratelimitter_tests.jl")
include("middleware/ratelimitter_lru_tests.jl")
include("middleware/authmiddleware_tests.jl")
include("middleware/cors_middleware_tests.jl")
include("middleware/lifecycle_middleware_tests.jl")
include("middleware/session_middleware_tests.jl")
include("middleware/guards_tests.jl")

end 
