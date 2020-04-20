VERSION?=0.0.0

build:
	gem build logstash-input-centrifyidplatform \
	&& logstash-plugin install logstash-input-centrifyidplatform-$(VERSION).gem

run:
	logstash -f logstash-input-centrifyidplatform-test.conf

install:
	logstash-plugin install logstash-input-centrifyidplatform

remove:
	logstash-plugin remove logstash-input-centrifyidplatform

publish:
	gem push logstash-input-centrifyidplatform-$(VERSION).gem

clean:
	rm logstash-input-centrifyidplatform-*.gem
