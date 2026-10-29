using Test, HTTP, Nitro, RealApp

@testset "RealApp" begin
    # A fresh App, so the test never touches `RealApp.app`, the one `main()` serves.
    app = App(mod = RealApp)
    urlpatterns(app, "", RealApp.Routes.urlpatterns())
    res = internalrequest(app, HTTP.Request("GET", "/health"))
    @test res.status == 200
end
