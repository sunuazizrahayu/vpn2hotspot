.PHONY: build

build: vpn2hotspot.zip

vpn2hotspot.zip: META-INF module.prop service.sh action.sh $(wildcard webroot/*)
	rm -rf vpn2hotspot.zip
	zip -r vpn2hotspot.zip META-INF module.prop service.sh action.sh webroot

clean:
	rm -rf vpn2hotspot.zip
