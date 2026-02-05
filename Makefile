.PHONY: all hub store edge clean test

all: hub store edge

hub:
	cd hub && mix deps.get && mix compile

store:
	cd store && cargo build --release

edge:
	cd edge && go build -o keyring ./cmd/keyring

test:
	cd hub && mix test
	cd store && cargo test
	cd edge && go test ./...

clean:
	cd hub && mix clean
	cd store && cargo clean
	cd edge && rm -f keyring

.PHONY: docker
docker:
	docker compose -f infra/docker-compose.yml up -d
