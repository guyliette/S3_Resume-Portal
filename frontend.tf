terraform {                        # Configure the Terraform providers required by this frontend stack.
  required_providers {             # Declare the external providers used by the configuration.
    aws = {                        # Declare the AWS provider for S3, CloudFront, ACM, and Route 53.
      source  = "hashicorp/aws"    # Use the official HashiCorp AWS provider.
      version = "~> 6.0"           # Require a compatible major version of the AWS provider.
    }                              # Finish the AWS provider declaration.
    random = {                     # Declare the Random provider for a unique S3 bucket suffix.
      source  = "hashicorp/random" # Use the official HashiCorp Random provider.
      version = "~> 3.0"           # Require a compatible major version of the Random provider.
    }                              # Finish the Random provider declaration.
  }                                # Finish the required providers block.
}                                  # Finish the Terraform configuration block.

provider "aws" {       # Configure AWS resources in the requested S3 region.
  region = "us-east-1" # Create the S3 bucket and regional AWS resources in us-east-1.
}                      # Finish the primary AWS provider configuration.

provider "aws" {        # Configure the aliased AWS provider used for the CloudFront certificate.
  alias  = "cloudfront" # Give the certificate provider an explicit alias.
  region = "us-east-1"  # Create the ACM certificate in CloudFront's required region.
}                       # Finish the CloudFront AWS provider configuration.

data "aws_route53_zone" "bafia_world" { # Find the existing public Route 53 hosted zone.
  name         = "bafia.world"          # Select the hosted zone for the application domain.
  private_zone = false                  # Require a public hosted zone for public DNS resolution.
}                                       # Finish the Route 53 zone lookup.

resource "random_id" "bucket_suffix" { # Generate a stable suffix for the globally unique bucket name.
  byte_length = 4                      # Generate four random bytes for the bucket suffix.
}                                      # Finish the random suffix resource.

resource "aws_s3_bucket" "frontend" {                          # Create the private S3 bucket that stores the frontend files.
  bucket = "terraform-frontend-${random_id.bucket_suffix.hex}" # Assign a globally unique bucket name.
}                                                              # Finish the S3 bucket resource.

resource "aws_s3_bucket_ownership_controls" "frontend" { # Configure object ownership for the frontend bucket.
  bucket = aws_s3_bucket.frontend.id                     # Apply ownership settings to the created frontend bucket.
  rule {                                                 # Define the bucket ownership rule.
    object_ownership = "BucketOwnerEnforced"             # Disable object ACLs and make the bucket owner authoritative.
  }                                                      # Finish the ownership rule.
}                                                        # Finish the S3 ownership controls resource.

resource "aws_s3_bucket_public_access_block" "frontend" { # Block every public access path to the S3 bucket.
  bucket                  = aws_s3_bucket.frontend.id     # Apply the public access block to the frontend bucket.
  block_public_acls       = true                          # Block public ACL creation.
  block_public_policy     = true                          # Block public bucket policies.
  ignore_public_acls      = true                          # Ignore any public ACLs that might exist.
  restrict_public_buckets = true                          # Restrict access to buckets with public policies.
}                                                         # Finish the S3 public access block resource.

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" { # Encrypt objects stored in the frontend bucket.
  bucket = aws_s3_bucket.frontend.id                                       # Apply default encryption to the created bucket.
  rule {                                                                   # Define the bucket encryption rule.
    apply_server_side_encryption_by_default {                              # Define the default server-side encryption method.
      sse_algorithm = "AES256"                                             # Use Amazon S3 managed server-side encryption.
    }                                                                      # Finish the default encryption configuration.
  }                                                                        # Finish the encryption rule.
}                                                                          # Finish the S3 encryption resource.

resource "aws_cloudfront_origin_access_control" "frontend" {                                 # Create CloudFront's signed access control for the S3 origin.
  name                              = "terraform-frontend-oac"                               # Name the CloudFront origin access control.
  description                       = "Allow CloudFront to read the private frontend bucket" # Describe the access purpose.
  origin_access_control_origin_type = "s3"                                                   # Configure the origin access control for an S3 origin.
  signing_behavior                  = "always"                                               # Sign every CloudFront request sent to S3.
  signing_protocol                  = "sigv4"                                                # Use AWS Signature Version 4 for origin requests.
}                                                                                            # Finish the CloudFront origin access control resource.

resource "aws_acm_certificate" "frontend" {   # Request the TLS certificate for the application hostname.
  provider          = aws.cloudfront          # Create the certificate through the us-east-1 provider alias.
  domain_name       = "terraform.bafia.world" # Request a certificate for the application subdomain.
  validation_method = "DNS"                   # Validate ownership using a DNS record in Route 53.
}                                             # Finish the ACM certificate request.

resource "aws_route53_record" "frontend_certificate_validation" {                                  # Publish the ACM DNS validation record.
  for_each = {                                                                                     # Create one record for each ACM domain validation option.
    for option in aws_acm_certificate.frontend.domain_validation_options : option.domain_name => { # Index validation data by domain name.
      name   = option.resource_record_name                                                         # Capture the ACM validation record name.
      record = option.resource_record_value                                                        # Capture the ACM validation record value.
      type   = option.resource_record_type                                                         # Capture the ACM validation record type.
    }                                                                                              # Finish the validation option mapping.
  }                                                                                                # Finish the validation record collection.
  zone_id = data.aws_route53_zone.bafia_world.zone_id                                              # Publish the record in the bafia.world hosted zone.
  name    = each.value.name                                                                        # Set the DNS record name supplied by ACM.
  type    = each.value.type                                                                        # Set the DNS record type supplied by ACM.
  ttl     = 60                                                                                     # Set a short TTL while certificate validation is completed.
  records = [each.value.record]                                                                    # Set the DNS record value supplied by ACM.
}                                                                                                  # Finish the ACM validation DNS record resource.

resource "aws_acm_certificate_validation" "frontend" {                                                       # Wait for ACM to validate the certificate.
  provider                = aws.cloudfront                                                                   # Validate through the us-east-1 provider alias.
  certificate_arn         = aws_acm_certificate.frontend.arn                                                 # Identify the certificate to validate.
  validation_record_fqdns = [for record in aws_route53_record.frontend_certificate_validation : record.fqdn] # Pass the created DNS validation records to ACM.
}                                                                                                            # Finish the ACM certificate validation resource.

resource "aws_cloudfront_distribution" "frontend" { # Create the HTTPS CDN distribution for the frontend.
  enabled             = true                        # Enable the CloudFront distribution.
  is_ipv6_enabled     = true                        # Enable IPv6 client access.
  default_root_object = "index.html"                # Serve index.html for requests to the distribution root.
  aliases             = ["terraform.bafia.world"]   # Attach the custom application hostname to CloudFront.
  price_class         = "PriceClass_All"            # Allow CloudFront to use all edge locations.

  origin {                                                                        # Define the private S3 bucket as the CloudFront origin.
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name # Use the S3 regional REST endpoint.
    origin_id                = "frontend-s3-origin"                               # Assign a stable identifier to the S3 origin.
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id   # Require CloudFront Origin Access Control for this origin.
  }                                                                               # Finish the CloudFront origin definition.

  default_cache_behavior {                              # Define caching and request behavior for the default path.
    target_origin_id       = "frontend-s3-origin"       # Route default requests to the private S3 origin.
    viewer_protocol_policy = "redirect-to-https"        # Redirect HTTP viewers to HTTPS.
    allowed_methods        = ["GET", "HEAD", "OPTIONS"] # Allow read and CORS preflight requests.
    cached_methods         = ["GET", "HEAD", "OPTIONS"] # Cache read and CORS preflight requests.
    compress               = true                       # Enable CloudFront compression when supported.
    forwarded_values {                                  # Define the values forwarded to the S3 origin.
      query_string = false                              # Do not vary cached objects by query string.
      cookies {                                         # Define cookie forwarding behavior.
        forward = "none"                                # Do not forward cookies to the static S3 origin.
      }                                                 # Finish the cookie forwarding configuration.
    }                                                   # Finish the forwarded values configuration.
  }                                                     # Finish the default cache behavior.

  custom_error_response {              # Handle missing frontend routes as SPA routes.
    error_code         = 403           # Handle S3 access-denied responses for client-side routes.
    response_code      = 200           # Return a successful response for the SPA shell.
    response_page_path = "/index.html" # Serve index.html for the client-side route.
  }                                    # Finish the 403 custom error response.

  custom_error_response {              # Handle missing frontend objects as SPA routes.
    error_code         = 404           # Handle missing-object responses for client-side routes.
    response_code      = 200           # Return a successful response for the SPA shell.
    response_page_path = "/index.html" # Serve index.html for the client-side route.
  }                                    # Finish the 404 custom error response.

  viewer_certificate {                                                                 # Configure the custom ACM certificate for viewer HTTPS.
    acm_certificate_arn      = aws_acm_certificate_validation.frontend.certificate_arn # Attach the validated ACM certificate.
    ssl_support_method       = "sni-only"                                              # Use SNI for modern browser HTTPS connections.
    minimum_protocol_version = "TLSv1.2_2021"                                          # Require a modern TLS protocol version.
  }                                                                                    # Finish the viewer certificate configuration.

  restrictions {                # Configure geographic access restrictions.
    geo_restriction {           # Define the geographic restriction mode.
      restriction_type = "none" # Allow requests from all countries.
    }                           # Finish the geographic restriction.
  }                             # Finish the distribution restrictions.
}                               # Finish the CloudFront distribution resource.

resource "aws_s3_bucket_policy" "frontend" {                         # Allow only this CloudFront distribution to read the bucket.
  bucket = aws_s3_bucket.frontend.id                                 # Attach the policy to the frontend bucket.
  policy = jsonencode({                                              # Build the S3 policy as structured JSON.
    Version = "2012-10-17"                                           # Set the IAM policy language version.
    Statement = [{                                                   # Define the single read permission statement.
      Sid    = "AllowCloudFrontServicePrincipalReadOnly"             # Identify the CloudFront read statement.
      Effect = "Allow"                                               # Allow the requested S3 action.
      Principal = {                                                  # Define the AWS principal receiving access.
        Service = "cloudfront.amazonaws.com"                         # Allow the CloudFront service principal.
      }                                                              # Finish the principal definition.
      Action   = "s3:GetObject"                                      # Allow CloudFront to read stored frontend objects.
      Resource = "${aws_s3_bucket.frontend.arn}/*"                   # Limit access to objects inside this bucket.
      Condition = {                                                  # Limit the permission to this exact CloudFront distribution.
        StringEquals = {                                             # Define the exact-match condition.
          "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn # Allow requests only from this distribution ARN.
        }                                                            # Finish the exact-match condition.
      }                                                              # Finish the policy condition.
    }]                                                               # Finish the policy statement list.
  })                                                                 # Finish the JSON policy document.
}                                                                    # Finish the S3 bucket policy resource.

resource "aws_route53_record" "frontend" {                                       # Create the application DNS alias record.
  zone_id = data.aws_route53_zone.bafia_world.zone_id                            # Publish the record in the bafia.world hosted zone.
  name    = "terraform.bafia.world"                                              # Set the application hostname.
  type    = "A"                                                                  # Create an IPv4 alias record.
  alias {                                                                        # Configure the record as an AWS alias to CloudFront.
    name                   = aws_cloudfront_distribution.frontend.domain_name    # Point the alias to the CloudFront distribution.
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id # Use CloudFront's Route 53 hosted zone ID.
    evaluate_target_health = false                                               # Do not evaluate target health for the CloudFront alias.
  }                                                                              # Finish the CloudFront alias configuration.
}                                                                                # Finish the application DNS record resource.

resource "aws_route53_record" "frontend_ipv6" {                                  # Create the application DNS alias record for IPv6 clients.
  zone_id = data.aws_route53_zone.bafia_world.zone_id                            # Publish the record in the bafia.world hosted zone.
  name    = "terraform.bafia.world"                                              # Set the application hostname.
  type    = "AAAA"                                                               # Create an IPv6 alias record.
  alias {                                                                        # Configure the record as an AWS alias to CloudFront.
    name                   = aws_cloudfront_distribution.frontend.domain_name    # Point the alias to the CloudFront distribution.
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id # Use CloudFront's Route 53 hosted zone ID.
    evaluate_target_health = false                                               # Do not evaluate target health for the CloudFront alias.
  }                                                                              # Finish the CloudFront alias configuration.
}                                                                                # Finish the IPv6 application DNS record resource.
