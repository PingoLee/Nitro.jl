module SPATests

using Test
using HTTP
using Nitro
using Nitro: spafiles, GET

@testset "SPA History Mode Tests" begin
    # Create a temporary directory structure to simulate an SPA build
    test_dir = mktempdir()
    
    # Create an index.html file
    index_path = joinpath(test_dir, "index.html")
    write(index_path, "<h1>SPA Index</h1>")
    
    # Create some static assets
    assets_dir = joinpath(test_dir, "assets")
    mkdir(assets_dir)
    app_js_path = joinpath(assets_dir, "app.js")
    write(app_js_path, "console.log('App loaded');")
    
    css_js_path = joinpath(assets_dir, "style.css")
    write(css_js_path, "body { color: red; }")

    @testset "spafiles mounts assets and falls back to index" begin
        # Reset any existing state
        resetstate()
        
        # Mount the SPA folder
        spafiles(test_dir, "app")
        
        serve(port=6065, async=true, show_banner=false)
        sleep(1)

        try
            # 1. Existing file request should return the exact file
            r_js = internalrequest(HTTP.Request("GET", "/app/assets/app.js"))
            @test r_js.status == 200
            @test String(r_js.body) == "console.log('App loaded');"
            
            # 2. Existing index.html
            r_idx = internalrequest(HTTP.Request("GET", "/app/index.html"))
            @test r_idx.status == 200
            @test String(r_idx.body) == "<h1>SPA Index</h1>"
            
            # 3. Requesting a non-existent file inside the SPA mount (e.g., deep linking /app/users/123)
            # This should FALL BACK to index.html
            r_fallback = internalrequest(HTTP.Request("GET", "/app/users/123"))
            @test r_fallback.status == 200
            @test String(r_fallback.body) == "<h1>SPA Index</h1>"
            
            # 4. Another random deep link
            r_fallback_2 = internalrequest(HTTP.Request("GET", "/app/login"))
            @test r_fallback_2.status == 200
            @test String(r_fallback_2.body) == "<h1>SPA Index</h1>"

            # 5. Check missing file outside of mount (should 404 naturally)
            r_outside = internalrequest(HTTP.Request("GET", "/other/path"))
            @test r_outside.status == 404
            
        finally
            terminate()
            resetstate()
        end
    end

    @testset "spafiles without index.html issues warning and doesn't fallback" begin
        empty_dir = mktempdir()
        js_path = joinpath(empty_dir, "script.js")
        write(js_path, "alert(1);")
        
        resetstate()
        
        # This should log a warning about missing index.html, but still serve script.js
        spafiles(empty_dir, "empty")
        
        serve(port=6065, async=true, show_banner=false)
        sleep(1)

        try
            # script is served
            r_script = internalrequest(HTTP.Request("GET", "/empty/script.js"))
            @test r_script.status == 200
            
            # fallback does NOT happen (should 404 because no index.html exists to fallback to)
            r_missing = internalrequest(HTTP.Request("GET", "/empty/missing"))
            @test r_missing.status == 404
        finally
            terminate()
            resetstate()
        end
    end
end

end
