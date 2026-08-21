FROM scratch
COPY result/bin/minimaldog
ENTRYPOINT ["/minimaldog"]
