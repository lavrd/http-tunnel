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

run: build
	zig-out/bin/http-tunnel

run_docker:
	docker run --rm -it \
		--name http-tunnel \
  	http-tunnel
