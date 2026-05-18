.PHONY: run

run:
	hugo server \
		--port 1313 \
		--bind localhost \
		--noHTTPCache \
		--ignoreCache \
		--disableFastRender \
		--disableLiveReload
