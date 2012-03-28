require 'rubygems'
require 'sinatra'
require 'net/http'
require 'open-uri'
require 'json'
require 'RMagick'

FACE_API_KEY       = ENV['FACE_API_KEY']
FACE_API_SECRET    = ENV['FACE_API_SECRET']
tmp_glasses        = Magick::Image.read('glasses.png').first
tmp_glasses.format = 'gif'
GLASSES            = tmp_glasses

get '/' do
  img_src = params[:src]
  if img_src
    content_type 'image/gif'
    response        = Net::HTTP.get(URI("http://api.face.com/faces/detect.json?api_key=#{FACE_API_KEY}&api_secret=#{FACE_API_SECRET}&urls=#{img_src}"))
    parsed_response = JSON.parse(response)
    
    tags      = parsed_response['photos'].first['tags']
    rotate    = !(params[:rotate]=='false' || params[:rotate]=='no')
    flip_flag = !(params[:flip]=='false' || params[:flip]=='no')
    
    final = Magick::ImageList.new
    
    original_image = Magick::Image.read(img_src).first
    10.downto(1).each do |n|
      cur_frame = original_image.dup
      tags.each do |tag|
        left_eye  = tag['eye_left']
        right_eye = tag['eye_right']
        eye_angle = angle_between_eyes(left_eye, right_eye)
        flip = tag['yaw'] > 0 && flip_flag
        if left_eye && right_eye && eye_angle
          cur_frame = DealWithIt.new(left_eye, right_eye, eye_angle, cur_frame, rotate, flip).shifted_glasses(-10 * n)
        end
      end
      final << cur_frame
    end
    
    centered_frame = Magick::Image.read(img_src).first
    tags.each do |tag|
      left_eye  = tag['eye_left']
      right_eye = tag['eye_right']
      eye_angle = angle_between_eyes(left_eye, right_eye)
      flip = tag['yaw'] > 0 && flip_flag
      if left_eye && right_eye && eye_angle
        centered_frame = DealWithIt.new(left_eye, right_eye, eye_angle, centered_frame, rotate, flip).centered_glasses
      end
    end
    
    txt = Magick::Draw.new
    centered_frame = centered_frame.annotate(txt, 0,0,0,0, 'Deal with it'){
      txt.font_family = 'monospace'
      txt.gravity = Magick::SouthGravity
      txt.pointsize = 36
      txt.stroke = '#ffffff'
      txt.stroke_width = 2
      txt.fill = '#000000'
      txt.font_weight = Magick::BoldWeight
    }
    
    5.times { final << centered_frame.dup }
    
    final.to_blob
  else
    content_type 'html'
    'Give it a src! http://deal-withify.heroku.com/?src='
  end
end

def angle_between_eyes(left_eye, right_eye)
  Math.atan((right_eye['y'] - left_eye['y'])/(right_eye['x'] - left_eye['x'])) * 180.0 / Math::PI
end

ORIG_GLASSES_MID_X, ORIG_GLASSES_MID_Y = [210, 30]
FLIP_GLASSES_MID_X, FLIP_GLASSES_MID_Y = [115, 23]
GLASSES_WIDTH_MULTIPLIER = 2.7

def rotate_point(center, point, angle)
  cx, cy = center
  px, py = point
  
  distance = Math.sqrt((cx-px)**2 + (cy-py)**2)
  
  [cx + Math.sin(Math::PI/180.0 * angle)*distance, cy + Math.cos(-Math::PI/180.0 * angle)*distance]
end

# Returns an overlaid image (image1 over image2) such that the point at coords coords1 on image1
# are over the point at coords2 on image2
def align_images(image1, image2, coords1, coords2)
  x1, y1 = coords1
  x2, y2 = coords2
  x_shift = x2 - x1
  y_shift = y2 - y1
  image2.composite(image1, x_shift, y_shift, Magick::OverCompositeOp)
end

class DealWithIt
  def initialize(left_eye, right_eye, angle, img, rotate, flip)
    @img           = img
    @img.format    = 'gif'
    @rotate        = rotate
    @flip          = flip
    @img_width     = @img.columns
    @img_height    = @img.rows
    @saved_glasses = nil
    
    left_eye_x = left_eye['x'] * @img_width / 100.0
    left_eye_y = left_eye['y'] * @img_height / 100.0
    right_eye_x = right_eye['x'] * @img_width / 100.0
    right_eye_y = right_eye['y'] * @img_height / 100.0
    
    @eye_distance  = Math.sqrt((left_eye_x - right_eye_x)**2 + (left_eye_y - right_eye_y)**2)
    eye_midpoint_x = left_eye_x + (right_eye_x - left_eye_x)/2.0
    eye_midpoint_y = left_eye_y + (right_eye_y - left_eye_y)/2.0
    @eye_midpoint  = [eye_midpoint_x, eye_midpoint_y]
    @angle         = angle
  end
  
  def shrunk_glasses_dimensions
    new_width = @eye_distance * GLASSES_WIDTH_MULTIPLIER
    scale = new_width / GLASSES.columns.to_f
    new_height = scale * GLASSES.rows.to_f
    [new_width, new_height]
  end
  
  def scaled_and_rotated_glasses
    return @saved_glasses if @saved_glasses
    new_glasses = GLASSES.resize(*self.shrunk_glasses_dimensions, Magick::TriangleFilter, 0.5)
    new_glasses.background_color = 'none'
    new_glasses.format = 'png'
    
    new_glasses.flop! if @flip
    new_glasses.rotate!(@angle) if @rotate
    
    @saved_glasses = new_glasses
  end
  
  def glasses_midpoint
    gwidth, gheight = self.shrunk_glasses_dimensions
    scale = gwidth / GLASSES.columns.to_f
    if @flip
      [FLIP_GLASSES_MID_X * scale, FLIP_GLASSES_MID_Y * scale]
    else
      [ORIG_GLASSES_MID_X * scale, ORIG_GLASSES_MID_Y * scale]
    end
  end
  
  def scaled_and_rotated_glasses_midpoint
    midx, midy = self.glasses_midpoint
    if @rotate
      # midx += 50 * Math.cos(@angle * Math::PI/180)
      # This pushes the glasses up the nose a bit.
      midy += (50 * Math.sin(@angle * Math::PI/180)).abs
    end
    [midx, midy]
  end
  
  def centered_glasses
    align_images(self.scaled_and_rotated_glasses, @img, self.scaled_and_rotated_glasses_midpoint, @eye_midpoint)
  end
  
  def shifted_glasses(y_shift)
    glasses_mid_x, glasses_mid_y = self.scaled_and_rotated_glasses_midpoint
    glasses_mid_y -= y_shift
    align_images(self.scaled_and_rotated_glasses, @img, [glasses_mid_x, glasses_mid_y], @eye_midpoint)
  end
end
