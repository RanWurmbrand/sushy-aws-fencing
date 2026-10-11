FROM registry.access.redhat.com/ubi9/python-311:latest
USER 0
# Install from a wheel built in a git checkout, not from a source tree.
# sushy-tools uses pbr, which enumerates package data from git metadata: a
# plain `pip install .` on a tree without .git silently drops every Jinja
# template, and the emulator then 500s on its first request. build.sh takes
# care of producing the wheel correctly.
COPY *.whl /tmp/
RUN pip install --no-cache-dir /tmp/*.whl 'boto3>=1.39.12' && rm -f /tmp/*.whl
USER 1001
EXPOSE 8000
CMD ["sushy-emulator", "--config", "/etc/sushy/aws.conf"]
