defmodule FloorControlWeb.SwaggerControllerTest do
  use FloorControlWeb.ConnCase

  @asset_checksums %{
    "priv/static/swagger/swagger-ui-5.11.10.css" =>
      "5ae746788ad6c2f19bb8c7638d63b5744e3efebaacb3bcabccdc928dbec6c4df",
    "priv/static/swagger/swagger-ui-5.11.10-bundle.js" =>
      "aebc65e339eb03b5f6fdc1cda2e4ac63282efa8aa3749a4482326894e065b152",
    "priv/static/swagger/swagger-ui-5.11.10-standalone-preset.js" =>
      "2f63f1a71ce7a6c7bd7b93000090138c11f6a95448adb0dd966f57e2dd5f0655",
    "priv/static/swagger/Swagger-UI-LICENSE.txt" =>
      "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
  }

  @asset_paths [
    "/swagger/swagger-ui-5.11.10.css",
    "/swagger/swagger-ui-5.11.10-bundle.js",
    "/swagger/swagger-ui-5.11.10-standalone-preset.js"
  ]

  test "GET /swagger serves the bundled UI", %{conn: conn} do
    response = conn |> get("/swagger") |> response(200)

    assert response =~ "SwaggerUIBundle"
    assert response =~ ~s(url: "/openapi.yaml")
    assert response =~ "validatorUrl: null"
    refute response =~ "http://"
    refute response =~ "https://"
    refute response =~ "validator.swagger.io"
  end

  test "GET /swagger/ serves the UI with relative asset paths", %{conn: conn} do
    assert conn |> get("/swagger/") |> response(200) =~ "Floor Control API - Swagger UI"
  end

  for asset_path <- @asset_paths do
    test "GET #{asset_path} serves a bundled asset", %{conn: conn} do
      conn = get(conn, unquote(asset_path))

      assert response(conn, 200) != ""
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end
  end

  test "bundled Swagger assets match their recorded checksums" do
    for {relative_path, expected_checksum} <- @asset_checksums do
      path = Path.expand("../../../#{relative_path}", __DIR__)

      actual_checksum =
        path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

      assert actual_checksum == expected_checksum
    end
  end

  test "bundled assets support conditional requests" do
    conn = get(build_conn(), "/swagger/swagger-ui-5.11.10.css")
    [etag] = get_resp_header(conn, "etag")

    conditional_conn =
      build_conn()
      |> put_req_header("if-none-match", etag)
      |> get("/swagger/swagger-ui-5.11.10.css")

    assert response(conditional_conn, 304) == ""
  end

  test "GET /openapi.yaml serves the repository contract", %{conn: conn} do
    conn = get(conn, "/openapi.yaml")
    repository_spec = File.read!(Path.expand("../../../OpenApiSpec.yaml", __DIR__))

    assert response(conn, 200) == repository_spec
    assert get_resp_header(conn, "content-type") == ["text/yaml; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["max-age=0, private, must-revalidate"]
    assert response(conn, 200) =~ "url: /"
  end

  test "the UI exposes the documented API route names", %{conn: conn} do
    spec = conn |> get("/openapi.yaml") |> response(200)

    for route <- [
          "/",
          "/ready",
          "/groups/{groupId}/floor",
          "/groups/{groupId}/floor/history",
          "/groups/{groupId}/floor/{userId}"
        ] do
      assert spec =~ route
    end
  end
end
