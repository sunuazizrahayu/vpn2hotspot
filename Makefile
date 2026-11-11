.PHONY: build

build: vpn-gateway.zip

vpn-gateway.zip: META-INF module.prop service.sh action.sh $(wildcard webroot/*)
	rm -rf vpn-gateway.zip
	zip -r vpn-gateway.zip META-INF module.prop service.sh action.sh webroot

clean:
	rm -rf vpn-gateway.zip
