FROM ruby:2.7.3-alpine

# Dependencies for setup and runtime
RUN apk --no-cache add nodejs yarn postgresql-client ffmpeg vips tzdata \
  git build-base postgresql-dev glib-dev


# Nice to have packages
RUN apk --no-cache add nano sudo bash

# shoreman
RUN wget -O /usr/bin/shoreman https://github.com/chrismytton/shoreman/raw/master/shoreman.sh \
  && chmod +x /usr/bin/shoreman

WORKDIR /app
CMD [ "shoreman" ]
