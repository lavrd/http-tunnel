format:
	zig fmt src/main.zig

build: format
	zig build --summary all

build_linux: format
	mkdir -p zig-out/linux/bin
	./build.sh

build_docker: build_linux
	docker build -t http-tunnel -f Dockerfile .

test: format
	zig test src/main.zig

test_one: format
	zig test src/main.zig --test-filter $(name)

run_client: build
	zig-out/bin/http-tunnel "{\"side\":\"Client\"}"

run_server: build
	zig-out/bin/http-tunnel "{\"side\":\"Server\"}"

run_client_docker:
	docker run --rm -it \
		--name http-tunnel-client \
  	http-tunnel "{\"side\":\"Client\"}"

run_server_docker:
	docker run --rm -it \
		--name http-tunnel-server \
		-p 14600:14600 \
  	http-tunnel "{\"side\":\"Server\"}"
